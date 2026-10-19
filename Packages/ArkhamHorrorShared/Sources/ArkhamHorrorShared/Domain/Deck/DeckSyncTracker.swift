import Foundation

protocol DeckSyncTracking: Sendable {
    func lastSyncedAt(for deckID: DeckID, on profile: ServerProfile) async -> Date?
    func lastSyncedDeck(for deckID: DeckID, on profile: ServerProfile) async -> Deck?
    func recordSync(_ deck: Deck, on profile: ServerProfile, at date: Date) async
    func clear() async
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
    private var decks: [String: Deck] = [:]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "arkham.deckSync.lastSyncedAt"
    ) {
        defaultsBox = DeckSyncDefaultsBox(defaults: defaults)
        self.storageKey = storageKey
        timestamps = defaults.dictionary(forKey: storageKey) as? [String: TimeInterval] ?? [:]
    }

    func lastSyncedAt(for deckID: DeckID, on profile: ServerProfile) -> Date? {
        guard let timestamp = timestamps[key(for: deckID, on: profile)] else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func lastSyncedDeck(for deckID: DeckID, on profile: ServerProfile) -> Deck? {
        decks[key(for: deckID, on: profile)]
    }

    func recordSync(_ deck: Deck, on profile: ServerProfile, at date: Date) {
        let storageKey = key(for: deck.id, on: profile)
        timestamps[storageKey] = date.timeIntervalSince1970
        decks[storageKey] = deck
        defaultsBox.defaults.set(timestamps, forKey: self.storageKey)
    }

    func clear() {
        timestamps = [:]
        decks = [:]
        defaultsBox.defaults.removeObject(forKey: storageKey)
    }

    private func key(for deckID: DeckID, on profile: ServerProfile) -> String {
        "\(profile.baseURL.absoluteString.lowercased())|\(deckID.rawValue.uuidString.lowercased())"
    }
}
