@testable import ArkhamHorrorShared
import Foundation
import Testing

/// ``BoardProjection/isChoiceActionable(_:story:)`` and
/// ``BoardDisplayFormatting/choiceAccessibilityHint(for:in:story:canSubmit:statusMessage:)``
/// coverage for issue djensenius/ArkhamHorror-Apple#35's presentation/action-authority
/// gate. Split out of `ReadStoryQuestionTests.swift` to keep both files under the
/// repository's `file_length`/`type_body_length` lint limits; shares that file's
/// `fixture`/`expectedLocationID` helpers via `ReadStoryQuestionTests`.
extension ReadStoryQuestionTests {
    // swiftlint:disable line_length

    // MARK: - isChoiceActionable presentation/action-authority gating (BoardProjection)

    @Test("isChoiceActionable is true for a location choice present in the projection")
    func isChoiceActionableTrueWhenLocationKnown() throws {
        let locationID = expectedLocationID("d5a66e84-c729-4066-8475-d8a155609025")
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: [
                (locationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: locationID, label: "Study"
                ))),
            ]
        ))
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-choose-one-location")
        )
        let choice = try #require(payload.supportedQuestion?.choices.first)
        #expect(projection.isChoiceActionable(choice))
    }

    @Test(
        "isChoiceActionable is false for a wire-supported location choice absent from the projection (missing at render)"
    )
    func isChoiceActionableFalseWhenLocationMissingAtRender() throws {
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-choose-one-location")
        )
        let choice = try #require(payload.supportedQuestion?.choices.first)
        #expect(choice.isSupported)
        #expect(!projection.isChoiceActionable(choice))
    }

    @Test("isChoiceActionable is false for a wire-unsupported choice regardless of the projection")
    func isChoiceActionableFalseForUnsupportedChoiceEvenIfLocationKnown() throws {
        let locationID = BoardTestFixtures.locationID("000000000398")
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: [
                (locationID, .ordinary(BoardTestFixtures.ordinaryLocation(id: locationID))),
            ]
        ))
        let bytes = Data(
            (
                #"{"tag":"ChooseOne","choices":["# +
                    #"{"tag":"TargetLabel","target":{"tag":"EnemyTarget","contents":"00000000-0000-0000-0000-000000000398"},"messages":[]}"# +
                    "]}"
            ).utf8
        )
        let payload = try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: bytes)
        let choice = try #require(payload.supportedQuestion?.choices.first)
        #expect(!choice.isSupported)
        #expect(!projection.isChoiceActionable(choice))
    }

    @Test("isChoiceActionable is always true for non-location choice kinds regardless of projection")
    func isChoiceActionableTrueForNonLocationChoices() throws {
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-choose-one")
        )
        let choice = try #require(payload.supportedQuestion?.choices.first)
        #expect(choice.locationID == nil)
        if case .continueReading = choice.content {
            Issue.record("expected a non-continueReading choice kind")
        }
        #expect(projection.isChoiceActionable(choice))
    }

    @Test(
        "A location choice's actionability tracks a location appearing, then disappearing, in successive projections -- never cached from an earlier snapshot"
    )
    func isChoiceActionableTracksLocationAppearingAndDisappearing() throws {
        let locationID = expectedLocationID("d5a66e84-c729-4066-8475-d8a155609025")
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-choose-one-location")
        )
        let choice = try #require(payload.supportedQuestion?.choices.first)

        let beforeReveal = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        #expect(!beforeReveal.isChoiceActionable(choice))

        let afterReveal = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: [
                (locationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: locationID, label: "Study"
                ))),
            ]
        ))
        #expect(afterReveal.isChoiceActionable(choice))

        // A later snapshot that stops carrying the location (for example an authoritative
        // rollback) must immediately revert to non-actionable -- this is never cached
        // from `afterReveal`.
        let afterRemoval = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        #expect(!afterRemoval.isChoiceActionable(choice))
    }

    @Test(
        "A mixed choices array of wire-unsupported, unknown-location, and known-location choices reports actionability per original index, never filtered/reindexed"
    )
    func mixedActionabilityPreservesOriginalIndices() throws {
        let knownLocationID = BoardTestFixtures.locationID("00000000039a")
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: [
                (knownLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: knownLocationID, label: "Known"
                ))),
            ]
        ))
        let bytes = Data(
            (
                #"{"tag":"ChooseOne","choices":["# +
                    #"{"tag":"TargetLabel","target":{"tag":"EnemyTarget","contents":"00000000-0000-0000-0000-000000000398"},"messages":[]},"# +
                    #"{"tag":"TargetLabel","target":{"tag":"LocationTarget","contents":"00000000-0000-0000-0000-000000000399"},"messages":[]},"# +
                    #"{"tag":"TargetLabel","target":{"tag":"LocationTarget","contents":"00000000-0000-0000-0000-00000000039a"},"messages":[]}"# +
                    "]}"
            ).utf8
        )
        let payload = try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: bytes)
        let question = try #require(payload.supportedQuestion)
        #expect(question.choices.map(\.index) == [0, 1, 2])
        #expect(question.choices.map(\.isSupported) == [false, true, true])
        #expect(question.choices.map { projection.isChoiceActionable($0) } == [false, false, true])
    }

    // MARK: - choiceAccessibilityHint (VoiceOver text, BoardDisplayFormatting)

    @Test("choiceAccessibilityHint distinguishes wire-unsupported from unavailable-location")
    func choiceAccessibilityHintDistinguishesUnsupportedFromUnavailable() throws {
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let unsupportedBytes = Data(
            (
                #"{"tag":"ChooseOne","choices":["# +
                    #"{"tag":"TargetLabel","target":{"tag":"EnemyTarget","contents":"00000000-0000-0000-0000-000000000398"},"messages":[]}"# +
                    "]}"
            ).utf8
        )
        let unsupportedPayload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: unsupportedBytes
        )
        let unsupportedChoice = try #require(unsupportedPayload.supportedQuestion?.choices.first)
        #expect(
            BoardDisplayFormatting.choiceAccessibilityHint(
                for: unsupportedChoice, in: projection, canSubmit: true, statusMessage: nil
            ) == "This choice requires a newer app version."
        )

        let locationPayload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-choose-one-location")
        )
        let locationChoice = try #require(locationPayload.supportedQuestion?.choices.first)
        #expect(locationChoice.isSupported)
        #expect(
            BoardDisplayFormatting.choiceAccessibilityHint(
                for: locationChoice, in: projection, canSubmit: true, statusMessage: nil
            ) == "This location isn't currently available."
        )
    }

    @Test("choiceAccessibilityHint announces activation for an actionable, submittable choice")
    func choiceAccessibilityHintAnnouncesActivation() throws {
        let locationID = expectedLocationID("d5a66e84-c729-4066-8475-d8a155609025")
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: [
                (locationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: locationID, label: "Study"
                ))),
            ]
        ))
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-choose-one-location")
        )
        let choice = try #require(payload.supportedQuestion?.choices.first)
        #expect(
            BoardDisplayFormatting.choiceAccessibilityHint(
                for: choice, in: projection, canSubmit: true, statusMessage: nil
            ) == "Activates choice 1."
        )
    }

    @Test(
        "choiceAccessibilityHint reports the read-only status message (or a deterministic fallback) for an actionable choice that cannot currently be submitted"
    )
    func choiceAccessibilityHintReportsReadOnlyState() throws {
        let locationID = expectedLocationID("d5a66e84-c729-4066-8475-d8a155609025")
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: [
                (locationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: locationID, label: "Study"
                ))),
            ]
        ))
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-choose-one-location")
        )
        let choice = try #require(payload.supportedQuestion?.choices.first)
        #expect(
            BoardDisplayFormatting.choiceAccessibilityHint(
                for: choice, in: projection, canSubmit: false, statusMessage: "Sending..."
            ) == "Sending..."
        )
        #expect(
            BoardDisplayFormatting.choiceAccessibilityHint(
                for: choice, in: projection, canSubmit: false, statusMessage: nil
            ) == "This choice is currently read-only."
        )
    }
    // swiftlint:enable line_length
}
