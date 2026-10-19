import Foundation

protocol DeckSyncTracking: Sendable {
    func lastSyncedAt(for deckID: DeckID) async -> Date?
    func recordSync(for deckID: DeckID, at date: Date) async
}

private final class DeckSyncDefaultsBox: @unchecked Sendable {
    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }
}

actor DeckSyncTracker: DeckSyncTracking {
    private let defaultsBox: DeckSyncDefaultsBox
    private let storageKey: String
    private var timestamps: [String: TimeInterval]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "arkham.deckSync.lastSyncedAt"
    ) {
        defaultsBox = DeckSyncDefaultsBox(defaults: defaults)
        self.storageKey = storageKey
        timestamps = defaults.dictionary(forKey: storageKey) as? [String: TimeInterval] ?? [:]
    }

    func lastSyncedAt(for deckID: DeckID) -> Date? {
        guard let timestamp = timestamps[key(for: deckID)] else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func recordSync(for deckID: DeckID, at date: Date) {
        timestamps[key(for: deckID)] = date.timeIntervalSince1970
        defaultsBox.defaults.set(timestamps, forKey: storageKey)
    }

    private func key(for deckID: DeckID) -> String {
        deckID.rawValue.uuidString.lowercased()
    }
}
