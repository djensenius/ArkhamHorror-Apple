@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
struct LiveChooseDeckSelectionViewTests {
    @Test("Overlapping deck send tasks cannot clear a newer spinner or set failure")
    func overlappingDeckSendAttemptsOnlyCurrentAttemptOwnsViewState() throws {
        var state = LiveChooseDeckSubmissionState()
        let oldDeckID = DeckID(UUID())
        let replacementDeckID = DeckID(UUID())
        let oldAttemptID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000101"))
        let replacementAttemptID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000102"))

        let oldAttempt = try #require(state.beginSending(
            deckID: oldDeckID,
            attemptID: oldAttemptID
        ))
        #expect(state.isSending(deckID: oldDeckID))
        #expect(state.beginSending(deckID: replacementDeckID) == nil)
        #expect(state.sendFailure == nil)

        state.releaseActiveAttemptIfPickerEnabled(true)
        let replacementAttempt = try #require(state.beginSending(
            deckID: replacementDeckID,
            attemptID: replacementAttemptID
        ))
        state.finish(oldAttempt, didSend: false)

        #expect(state.activeAttempt == replacementAttempt)
        #expect(!state.isSending(deckID: oldDeckID))
        #expect(state.isSending(deckID: replacementDeckID))
        #expect(state.sendFailure == nil)

        state.finish(replacementAttempt, didSend: false)
        #expect(state.activeAttempt == nil)
        #expect(state.sendFailure == LiveChooseDeckSubmissionState.sendFailureMessage)
    }

    @Test("Deck send spinner is released only after the picker becomes enabled")
    func activeDeckSendAttemptIsReleasedOnlyWhenPickerIsEnabled() throws {
        var state = LiveChooseDeckSubmissionState()
        let deckID = DeckID(UUID())
        let attemptID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000103"))
        let attempt = try #require(state.beginSending(deckID: deckID, attemptID: attemptID))

        state.releaseActiveAttemptIfPickerEnabled(false)
        #expect(state.activeAttempt == attempt)
        #expect(state.isSending(deckID: deckID))

        state.releaseActiveAttemptIfPickerEnabled(true)
        #expect(state.activeAttempt == nil)
        #expect(!state.isSending(deckID: deckID))
    }
}
