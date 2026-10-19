@testable import ArkhamHorrorShared
import Foundation

actor RecordingDeckSyncTracker: DeckSyncTracking {
    private(set) var records: [(DeckID, Date)] = []
    private(set) var recordedIDs: [DeckID] = []
    private var decks: [DeckID: Deck] = [:]
    private var isRecordGated = false
    private var recordContinuation: CheckedContinuation<Void, Never>?
    private var recordWaiter: CheckedContinuation<Void, Never>?

    func setRecordGated(_ gated: Bool) {
        isRecordGated = gated
    }

    func waitUntilRecordPending() async {
        if recordContinuation != nil {
            return
        }
        await withCheckedContinuation { recordWaiter = $0 }
    }

    func resumeRecord() {
        recordContinuation?.resume()
        recordContinuation = nil
        isRecordGated = false
    }

    func lastSyncedAt(for _: DeckID, on _: ServerProfile) -> Date? {
        nil
    }

    func lastSyncedDeck(for deckID: DeckID, on _: ServerProfile) -> Deck? {
        decks[deckID]
    }

    func recordSync(_ deck: Deck, on _: ServerProfile, at date: Date) async {
        recordedIDs.append(deck.id)
        if isRecordGated {
            await withCheckedContinuation { continuation in
                recordContinuation = continuation
                recordWaiter?.resume()
                recordWaiter = nil
            }
        }
        records.append((deck.id, date))
        decks[deck.id] = deck
    }

    func removeSync(for deckID: DeckID, on _: ServerProfile) {
        records.removeAll { $0.0 == deckID }
        decks[deckID] = nil
    }

    func clear() {
        records = []
        decks = [:]
    }
}
