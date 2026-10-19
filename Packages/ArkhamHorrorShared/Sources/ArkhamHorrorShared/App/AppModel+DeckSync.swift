import Foundation

private struct DeckChoiceSyncTimeoutError: Error {}

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
    func deckChoiceSyncNote(for deckID: DeckID) -> String? {
        guard let note = deckChoiceSyncNotes[deckID] else { return nil }
        if note.isExpired {
            deckChoiceSyncNotes[deckID] = nil
            return nil
        }
        return note.message
    }

    func deckChoiceIsSyncing(_ deckID: DeckID) -> Bool {
        deckChoiceSyncingIDs.contains(deckID)
    }

    func deckForChoice(_ deck: Deck) -> Deck {
        deckChoiceSyncedDecks[deck.id] ?? deck
    }

    func recordSyncedDeckForChoice(_ deck: Deck) {
        deckChoiceSyncedDecks[deck.id] = deck
    }

    func resetDeckChoiceSyncState() async {
        deckChoiceSyncNotes = [:]
        deckChoiceSyncedDecks = [:]
        deckChoiceSyncingIDs = []
        await deckSyncTracker.clear()
    }

    func syncDeckBeforeChoiceIfNeeded(
        _ deck: Deck,
        profile: ServerProfile,
        token: String
    ) async -> DeckChoiceSyncResult {
        guard deck.hasSyncURL else {
            deckChoiceSyncNotes[deck.id] = nil
            deckChoiceSyncingIDs.remove(deck.id)
            return DeckChoiceSyncResult(deck: deck, note: nil, didAttemptSync: false)
        }

        if let cachedDeck = await recentlySyncedChoiceDeck(deck, profile: profile) {
            return DeckChoiceSyncResult(deck: cachedDeck, note: nil, didAttemptSync: false)
        }

        deckChoiceSyncingIDs.insert(deck.id)
        let service = deckService
        let timeout = deckChoiceSyncTimeout
        do {
            let syncedDeck = try await withDeckChoiceSyncTimeout(seconds: timeout) {
                try await service.syncDeck(
                    deck.id,
                    on: profile,
                    token: token,
                    timeout: timeout
                )
            }
            let syncedAt = Date()
            await deckSyncTracker.recordSync(syncedDeck, on: profile, at: syncedAt)
            recordSyncedDeckForChoice(syncedDeck)
            let note = deckSyncSuccessMessage()
            deckChoiceSyncNotes[deck.id] = DeckChoiceSyncNote(
                message: note,
                expiresAt: syncedAt.addingTimeInterval(deckChoiceSyncMinimumInterval)
            )
            deckChoiceSyncingIDs.remove(deck.id)
            return DeckChoiceSyncResult(deck: syncedDeck, note: note, didAttemptSync: true)
        } catch is CancellationError {
            deckChoiceSyncingIDs.remove(deck.id)
            return DeckChoiceSyncResult(deck: deckForChoice(deck), note: nil, didAttemptSync: true)
        } catch GameLifecycleTokenAccessError.stale {
            deckChoiceSyncingIDs.remove(deck.id)
            return DeckChoiceSyncResult(deck: deckForChoice(deck), note: nil, didAttemptSync: true)
        } catch {
            let fallbackDeck = deckForChoice(deck)
            let note = deckSyncStaleFallbackMessage()
            deckChoiceSyncNotes[deck.id] = DeckChoiceSyncNote(message: note, expiresAt: nil)
            deckChoiceSyncingIDs.remove(deck.id)
            return DeckChoiceSyncResult(deck: fallbackDeck, note: note, didAttemptSync: true)
        }
    }

    private func recentlySyncedChoiceDeck(
        _ deck: Deck,
        profile: ServerProfile
    ) async -> Deck? {
        guard let lastSyncedAt = await deckSyncTracker.lastSyncedAt(for: deck.id, on: profile),
              Date().timeIntervalSince(lastSyncedAt) < deckChoiceSyncMinimumInterval
        else { return nil }
        if let cachedDeck = await deckSyncTracker.lastSyncedDeck(for: deck.id, on: profile) {
            recordSyncedDeckForChoice(cachedDeck)
            return cachedDeck
        }
        return deckForChoice(deck)
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
    deckLocalized("deck.sync.success", "Synced with ArkhamDB just now.")
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
