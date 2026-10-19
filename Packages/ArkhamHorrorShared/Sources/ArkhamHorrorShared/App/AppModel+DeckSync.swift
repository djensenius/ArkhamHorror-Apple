import Foundation

private struct DeckChoiceSyncTimeoutError: Error {}

struct DeckChoiceSyncResult: Sendable, Equatable {
    let deck: Deck
    let note: String?
    let didAttemptSync: Bool
}

extension AppModel {
    func deckChoiceSyncNote(for deckID: DeckID) -> String? {
        deckChoiceSyncNotes[deckID]
    }

    func syncDeckBeforeChoiceIfNeeded(
        _ deck: Deck,
        profile: ServerProfile,
        token: String
    ) async -> DeckChoiceSyncResult {
        guard deck.hasSyncURL else {
            deckChoiceSyncNotes[deck.id] = nil
            return DeckChoiceSyncResult(deck: deck, note: nil, didAttemptSync: false)
        }

        let now = Date()
        if let lastSyncedAt = await deckSyncTracker.lastSyncedAt(for: deck.id) {
            let elapsed = now.timeIntervalSince(lastSyncedAt)
            if elapsed < deckChoiceSyncMinimumInterval {
                return DeckChoiceSyncResult(deck: deck, note: nil, didAttemptSync: false)
            }
        }

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
            await deckSyncTracker.recordSync(for: deck.id, at: syncedAt)
            let note = deckSyncSuccessMessage()
            deckChoiceSyncNotes[deck.id] = note
            return DeckChoiceSyncResult(deck: syncedDeck, note: note, didAttemptSync: true)
        } catch is CancellationError {
            return DeckChoiceSyncResult(deck: deck, note: nil, didAttemptSync: true)
        } catch {
            let savedAt = await deckSyncTracker.lastSyncedAt(for: deck.id)
            let note = deckSyncStaleFallbackMessage(savedAt: savedAt)
            deckChoiceSyncNotes[deck.id] = note
            return DeckChoiceSyncResult(deck: deck, note: note, didAttemptSync: true)
        }
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

func deckSyncStaleFallbackMessage(savedAt: Date?) -> String {
    guard let savedAt else {
        return deckLocalized(
            "deck.sync.staleFallback.unknownDate",
            "Couldn't reach ArkhamDB; using the saved version from an unknown date."
        )
    }
    return deckLocalizedFormat(
        "deck.sync.staleFallback",
        "Couldn't reach ArkhamDB; using the saved version from %@.",
        deckSyncDateString(savedAt)
    )
}

func deckSyncDateString(_ date: Date) -> String {
    DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
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
