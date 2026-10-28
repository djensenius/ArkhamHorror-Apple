import Foundation

private struct DeckChoiceSyncTimeoutError: Error {}

struct DeckChoiceValidationFailure: Error {
    let message: String
}

struct DeckChoiceSyncKey: Sendable, Hashable {
    private let serverBaseURL: String
    private let deckID: DeckID

    init(deckID: DeckID, on profile: ServerProfile) {
        serverBaseURL = profile.baseURL.absoluteString.lowercased()
        self.deckID = deckID
    }
}

struct DeckChoiceSyncNote: Sendable, Equatable {
    let message: String
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}

struct DeckChoiceSyncResult: Sendable, Equatable {
    let deck: Deck
    let note: String?
    let didAttemptSync: Bool
}

extension AppModel {
    func deckChoiceSyncNote(for deckID: DeckID, on profile: ServerProfile) -> String? {
        guard let note = deckChoiceSyncNotes[DeckChoiceSyncKey(deckID: deckID, on: profile)],
              !note.isExpired
        else { return nil }
        return note.message
    }

    func deckChoiceIsSyncing(_ deckID: DeckID, on profile: ServerProfile) -> Bool {
        deckChoiceSyncingIDs.contains(DeckChoiceSyncKey(deckID: deckID, on: profile))
    }

    func deckForChoice(_ deck: Deck, on profile: ServerProfile) -> Deck {
        deckChoiceSyncedDecks[DeckChoiceSyncKey(deckID: deck.id, on: profile)] ?? deck
    }

    func recordSyncedDeckForChoice(_ deck: Deck, on profile: ServerProfile) {
        deckChoiceSyncedDecks[DeckChoiceSyncKey(deckID: deck.id, on: profile)] = deck
    }

    func recordLoadedDecksForChoice(_ decks: [Deck], on profile: ServerProfile) async {
        for deck in decks {
            let key = DeckChoiceSyncKey(deckID: deck.id, on: profile)
            var shouldForgetTracker = false
            if let cachedDeck = deckChoiceSyncedDecks[key], cachedDeck != deck {
                deckChoiceSyncedDecks[key] = nil
                deckChoiceSyncNotes[key] = nil
                shouldForgetTracker = true
            }
            if await trackerHasDifferentDeckBody(deck, on: profile) {
                shouldForgetTracker = true
            }
            if shouldForgetTracker {
                await deckSyncTracker.removeSync(for: deck.id, on: profile)
            }
        }
    }

    func resetDeckChoiceSyncState() {
        deckChoiceSyncNotes = [:]
        deckChoiceSyncedDecks = [:]
        deckChoiceSyncingIDs = []
    }

    func clearDeckChoiceSyncTracker() async {
        await deckSyncTracker.clear()
    }

    func isCurrentDeckRequestContext(
        _ context: DeckRequestContext,
        for profile: ServerProfile
    ) -> Bool {
        guard isCurrent(context.sessionGeneration),
              currentCredentialEpoch(for: profile.id) == context.credentialEpoch,
              currentGlobalCredentialEpoch() == context.globalEpoch,
              case let .signedIn(currentProfile, _, _) = sessionState,
              currentProfile == profile
        else { return false }
        return true
    }

    func syncDeckBeforeChoiceIfNeeded(
        _ deck: Deck,
        profile: ServerProfile,
        context: DeckRequestContext
    ) async throws -> DeckChoiceSyncResult {
        let result = try await resolveDeckChoiceSync(deck, profile: profile, context: context)
        // Picker validation is keyed by ID, not list contents. Even a cache hit may
        // contain a different list from the one the picker originally validated.
        if deck.hasSyncURL {
            try await validateResolvedDeckForChoice(result.deck, profile: profile, context: context)
            if result.note == nil {
                deckChoiceSyncNotes[DeckChoiceSyncKey(deckID: deck.id, on: profile)] = nil
            }
        }
        return result
    }

    private func validateResolvedDeckForChoice(
        _ deck: Deck,
        profile: ServerProfile,
        context: DeckRequestContext
    ) async throws {
        let service = deckService(on: profile)
        do {
            _ = try await withDeckChoiceSyncTimeout(seconds: deckChoiceSyncTimeout) {
                try await service.validateDeckList(
                    DeckListInput(deck.playableList), on: profile, token: context.token
                )
            }
        } catch DeckServiceError.sessionExpired {
            throw DeckServiceError.sessionExpired
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ensureCurrentDeckChoiceContext(context, on: profile)
            // Match the picker: transport failures block selection, using the
            // service's message or its generic validation-failure message.
            let message = (error as? DeckServiceError)?.message
                ?? "Deck validation failed. Try again."
            deckChoiceSyncNotes[DeckChoiceSyncKey(deckID: deck.id, on: profile)] =
                DeckChoiceSyncNote(message: message, expiresAt: nil)
            throw DeckChoiceValidationFailure(message: message)
        }
        try ensureCurrentDeckChoiceContext(context, on: profile)
    }

    private func resolveDeckChoiceSync(
        _ deck: Deck,
        profile: ServerProfile,
        context: DeckRequestContext
    ) async throws -> DeckChoiceSyncResult {
        try ensureCurrentDeckChoiceContext(context, on: profile)
        let key = DeckChoiceSyncKey(deckID: deck.id, on: profile)
        guard deck.hasSyncURL else {
            clearDeckChoiceSync(for: key)
            return DeckChoiceSyncResult(deck: deck, note: nil, didAttemptSync: false)
        }

        if let cachedDeck = try await recentlySyncedChoiceDeck(
            deck,
            profile: profile,
            context: context
        ) {
            return DeckChoiceSyncResult(deck: cachedDeck, note: nil, didAttemptSync: false)
        }

        deckChoiceSyncingIDs.insert(key)
        defer { deckChoiceSyncingIDs.remove(key) }
        do {
            let syncedDeck = try await syncChoiceDeck(deck, profile: profile, context: context)
            return try await recordSuccessfulDeckChoiceSync(
                syncedDeck,
                key: key,
                profile: profile,
                context: context
            )
        } catch DeckServiceError.sessionExpired {
            throw DeckServiceError.sessionExpired
        } catch is CancellationError {
            throw CancellationError()
        } catch GameLifecycleTokenAccessError.stale {
            throw GameLifecycleTokenAccessError.stale
        } catch let DeckServiceError.arkhamDB(error) where error?.requiresRelinking == true {
            try ensureCurrentDeckChoiceContext(context, on: profile)
            let note = arkhamDBErrorMessage(error)
            deckChoiceSyncNotes[key] = DeckChoiceSyncNote(message: note, expiresAt: nil)
            return DeckChoiceSyncResult(
                deck: deckForChoice(deck, on: profile),
                note: note,
                didAttemptSync: true
            )
        } catch {
            return try fallbackDeckChoiceSyncResult(
                for: deck,
                key: key,
                profile: profile,
                context: context
            )
        }
    }

    private func trackerHasDifferentDeckBody(
        _ deck: Deck,
        on profile: ServerProfile
    ) async -> Bool {
        guard let trackedDeck = await deckSyncTracker.lastSyncedDeck(
            for: deck.id,
            on: profile
        ) else { return false }
        return trackedDeck != deck
    }

    private func clearDeckChoiceSync(for key: DeckChoiceSyncKey) {
        deckChoiceSyncNotes[key] = nil
        deckChoiceSyncingIDs.remove(key)
    }

    private func syncChoiceDeck(
        _ deck: Deck,
        profile: ServerProfile,
        context: DeckRequestContext
    ) async throws -> Deck {
        let service = deckService(on: profile)
        let timeout = deckChoiceSyncTimeout
        return try await withDeckChoiceSyncTimeout(seconds: timeout) {
            try await service.syncDeck(
                deck.id,
                on: profile,
                token: context.token,
                timeout: timeout
            )
        }
    }

    private func recordSuccessfulDeckChoiceSync(
        _ syncedDeck: Deck,
        key: DeckChoiceSyncKey,
        profile: ServerProfile,
        context: DeckRequestContext
    ) async throws -> DeckChoiceSyncResult {
        try ensureCurrentDeckChoiceContext(context, on: profile)
        let syncedAt = Date()
        await deckSyncTracker.recordSync(syncedDeck, on: profile, at: syncedAt)
        try ensureCurrentDeckChoiceContext(context, on: profile)
        recordSyncedDeckForChoice(syncedDeck, on: profile)
        let note = deckSyncSuccessMessage()
        deckChoiceSyncNotes[key] = DeckChoiceSyncNote(
            message: note,
            expiresAt: syncedAt.addingTimeInterval(deckChoiceSyncMinimumInterval)
        )
        return DeckChoiceSyncResult(deck: syncedDeck, note: note, didAttemptSync: true)
    }

    private func fallbackDeckChoiceSyncResult(
        for deck: Deck,
        key: DeckChoiceSyncKey,
        profile: ServerProfile,
        context: DeckRequestContext
    ) throws -> DeckChoiceSyncResult {
        try ensureCurrentDeckChoiceContext(context, on: profile)
        let fallbackDeck = deckForChoice(deck, on: profile)
        let note = deckSyncStaleFallbackMessage()
        deckChoiceSyncNotes[key] = DeckChoiceSyncNote(message: note, expiresAt: nil)
        return DeckChoiceSyncResult(deck: fallbackDeck, note: note, didAttemptSync: true)
    }

    private func recentlySyncedChoiceDeck(
        _ deck: Deck,
        profile: ServerProfile,
        context: DeckRequestContext
    ) async throws -> Deck? {
        let lastSyncedAt = await deckSyncTracker.lastSyncedAt(for: deck.id, on: profile)
        try ensureCurrentDeckChoiceContext(context, on: profile)
        guard let lastSyncedAt,
              Date().timeIntervalSince(lastSyncedAt) < deckChoiceSyncMinimumInterval
        else { return nil }
        if let cachedDeck = await deckSyncTracker.lastSyncedDeck(for: deck.id, on: profile) {
            try ensureCurrentDeckChoiceContext(context, on: profile)
            recordSyncedDeckForChoice(cachedDeck, on: profile)
            return cachedDeck
        }
        try ensureCurrentDeckChoiceContext(context, on: profile)
        return deckForChoice(deck, on: profile)
    }

    private func ensureCurrentDeckChoiceContext(
        _ context: DeckRequestContext,
        on profile: ServerProfile
    ) throws {
        guard !Task.isCancelled,
              isCurrentDeckRequestContext(context, for: profile)
        else { throw GameLifecycleTokenAccessError.stale }
    }

    private func withDeckChoiceSyncTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let nanoseconds = max(0, Int64((seconds * 1_000_000_000).rounded(.up)))
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .nanoseconds(nanoseconds))
                throw DeckChoiceSyncTimeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw DeckChoiceSyncTimeoutError()
            }
            return result
        }
    }
}

extension Deck {
    var hasSyncURL: Bool {
        guard let url else { return false }
        return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

func deckSyncSuccessMessage() -> String {
    deckLocalized("deck.sync.success", "Synced with the deck source just now.")
}

func deckSyncStaleFallbackMessage() -> String {
    deckLocalized(
        "deck.sync.staleFallback",
        "Couldn't sync this deck; using the saved version."
    )
}

func deckLocalized(_ key: String, _ fallback: String) -> String {
    NSLocalizedString(key, bundle: .module, value: fallback, comment: "")
}

func deckLocalizedFormat(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
    String(
        format: deckLocalized(key, fallback),
        locale: Locale(identifier: Locale.current.identifier),
        arguments: arguments
    )
}
