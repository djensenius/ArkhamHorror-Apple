@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Basic choice focus")
struct BasicChoiceFocusTests {
    private func actionablePrompt() throws -> BasicChoicePromptPresentation {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: Data(
                """
                {"tag":"ChooseOne","choices":[
                  {"tag":"EndTurnButton","investigatorId":"c01001","messages":[]},
                  {"tag":"FutureChoice","messages":[]}
                ]}
                """.utf8
            )
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 3,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private func retryablePrompt() throws -> BasicChoicePromptPresentation {
        let prompt = try actionablePrompt()
        return BasicChoicePromptPresentation(
            identity: prompt.identity,
            question: prompt.question,
            readOnlyReason: nil,
            actionPhase: .retryable(.outcomeUncertain),
            actionChoiceIndex: 0,
            serverFeedback: nil
        )
    }

    func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name, withExtension: "json", subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    /// Builds a real ``question-read-with-cards.json``-decoded story-continue
    /// presentation, proving this feature's synthesized single-choice array flows through
    /// the exact same generic prompt focus/activation machinery as every other
    /// ``BasicChoiceQuestion`` kind, with no parallel focus path. This fixture (rather
    /// than the real production ``question-read.json``) is used because its
    /// `BasicEntry`-only flavor text resolves lawfully (see
    /// `StoryNarrativeLocalizationTests`), leaving the choice actionable so
    /// focus/activation machinery -- not story-content resolution, covered separately --
    /// is what's under test here.
    private func storyPrompt() throws -> BasicChoicePromptPresentation {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-read-with-cards")
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 1,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    /// A hand-crafted `ChooseOne` with an unsupported `EnemyTarget` choice at index 0
    /// followed by two real-UUID `TargetLabel(LocationTarget)` choices at indices 1/2 --
    /// proving focus jump/activation skip a leading unsupported entry to the first
    /// *supported* index without ever filtering/reindexing the array itself.
    private func locationPromptLeadingUnsupported() throws -> BasicChoicePromptPresentation {
        // swiftlint:disable line_length
        let bytes = Data(
            (
                #"{"tag":"ChooseOne","choices":["# +
                    #"{"tag":"TargetLabel","target":{"tag":"EnemyTarget","contents":"00000000-0000-0000-0000-000000000398"},"messages":[]},"# +
                    #"{"tag":"TargetLabel","target":{"tag":"LocationTarget","contents":"00000000-0000-0000-0000-000000000399"},"messages":[]},"# +
                    #"{"tag":"TargetLabel","target":{"tag":"LocationTarget","contents":"00000000-0000-0000-0000-00000000039a"},"messages":[]}"# +
                    "]}"
            ).utf8
        )
        // swiftlint:enable line_length
        let payload = try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: bytes)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 2,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    /// A `ChooseOne` with three real, fully wire-*supported* `TargetLabel(LocationTarget)`
    /// choices (unlike ``locationPromptLeadingUnsupported()``, every one of these parses
    /// as `isSupported == true`) — used to prove actionability gating driven purely by
    /// the current projection's known locations, entirely independent of wire-parse
    /// validity.
    private func threeSupportedLocationChoices() throws -> BasicChoicePromptPresentation {
        // swiftlint:disable line_length
        let bytes = Data(
            (
                #"{"tag":"ChooseOne","choices":["# +
                    #"{"tag":"TargetLabel","target":{"tag":"LocationTarget","contents":"00000000-0000-0000-0000-000000000398"},"messages":[]},"# +
                    #"{"tag":"TargetLabel","target":{"tag":"LocationTarget","contents":"00000000-0000-0000-0000-000000000399"},"messages":[]},"# +
                    #"{"tag":"TargetLabel","target":{"tag":"LocationTarget","contents":"00000000-0000-0000-0000-00000000039a"},"messages":[]}"# +
                    "]}"
            ).utf8
        )
        // swiftlint:enable line_length
        let payload = try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: bytes)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 2,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    @Test("Jump targets the first actionable choice and primary action preserves its exact index")
    func promptJumpAndPrimaryAction() throws {
        var submitted: [Int] = []
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let controller = try BoardCommandController(
            projection: projection,
            prompt: actionablePrompt(),
            onChoice: { submitted.append($0) }
        )

        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0])

        controller.updateChoiceHandler { submitted.append($0 + 10) }
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0, 10])
    }

    @Test("Prompt back and removal restore deterministic board focus")
    func promptFocusRestoration() throws {
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let controller = try BoardCommandController(
            projection: projection, prompt: actionablePrompt()
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.handle(.reservedBack))
        #expect(controller.coordinator.currentFocus == BoardFocusID.scenarioHeader)

        #expect(controller.handle(.command(.jumpToActivePrompt)))
        controller.applyPrompt(nil)
        #expect(controller.coordinator.currentFocus == BoardFocusID.scenarioHeader)
    }

    @Test("Toggle prompt surface enters and leaves the actionable prompt")
    func togglePromptSurface() throws {
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let controller = try BoardCommandController(
            projection: projection, prompt: actionablePrompt()
        )
        #expect(controller.handle(.command(.togglePromptSurface)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.handle(.command(.togglePromptSurface)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.scenarioHeader)
    }

    @Test("Retry state has deterministic semantic focus and controller activation")
    func retryFocusAndActivation() throws {
        var retries = 0
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let controller = try BoardCommandController(
            projection: projection,
            prompt: retryablePrompt(),
            onRetry: { retries += 1 }
        )

        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptRetry)
        #expect(controller.handle(.command(.primaryAction)))
        #expect(retries == 1)
    }

    @Test("A real Read continue prompt jumps to and activates its single choice at index 0")
    func storyPromptJumpAndPrimaryAction() throws {
        var submitted: [Int] = []
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let controller = try BoardCommandController(
            projection: projection,
            prompt: storyPrompt(),
            onChoice: { submitted.append($0) }
        )

        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0])
    }

    // swiftlint:disable line_length
    @Test(
        "A location prompt with a leading unsupported choice jumps to the first supported index and rejects direct activation of the disabled entry, never filtering/reindexing"
    )
    // swiftlint:enable line_length
    func locationPromptSkipsLeadingUnsupportedChoiceWithoutReindexing() throws {
        var submitted: [Int] = []
        // Both real `LocationTarget` choices (indices 1/2) must be authoritatively known
        // to the projection for this test to exercise *only* wire-`isSupported` gating at
        // index 0 (the `EnemyTarget`) -- independent of the separate location-actionability
        // gating ``locationPromptSkipsUnknownLocationChoiceWithoutReindexing`` covers.
        let knownLocationIDs = [
            BoardTestFixtures.locationID("000000000399"),
            BoardTestFixtures.locationID("00000000039a"),
        ]
        let projection = BoardProjectionBuilder.makeProjection(
            from: BoardTestFixtures.snapshot(
                locations: knownLocationIDs.map {
                    ($0, .ordinary(BoardTestFixtures.ordinaryLocation(id: $0)))
                }
            )
        )
        let controller = try BoardCommandController(
            projection: projection,
            prompt: locationPromptLeadingUnsupported(),
            onChoice: { submitted.append($0) }
        )

        // Jump skips index 0 (unsupported) and lands on index 1 -- its exact original
        // array position, not a re-sorted position 0.
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(1))

        // Direct activation of the disabled index is rejected outright: no submission,
        // no focus change, no silent promotion to a supported choice.
        #expect(!controller.activatePromptChoice(0))
        #expect(submitted.isEmpty)

        // Activating the focused (supported) index submits its exact original index.
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [1])

        // The final supported choice remains reachable and submits its own exact index.
        #expect(controller.activatePromptChoice(2))
        #expect(submitted == [1, 2])
    }

    // swiftlint:disable line_length
    @Test(
        "A wire-supported but not-yet-known location choice is skipped by focus and rejected on direct activation, without being reindexed or reported unsupported"
    )
    // swiftlint:enable line_length
    func locationPromptSkipsUnknownLocationChoiceWithoutReindexing() throws {
        var submitted: [Int] = []
        // Only the second (index 1) of the three real, fully wire-supported location
        // choices is present in the authoritative projection -- indices 0 and 2 remain
        // `isSupported == true` (they parsed as perfectly well-formed `TargetLabel`
        // choices) but are not yet actionable, exercising presentation/action-authority
        // gating that is entirely independent of wire-parse validity.
        let knownLocationID = BoardTestFixtures.locationID("000000000399")
        let projection = BoardProjectionBuilder.makeProjection(
            from: BoardTestFixtures.snapshot(
                locations: [
                    (knownLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                        id: knownLocationID, label: "Known location"
                    ))),
                ]
            )
        )
        let controller = try BoardCommandController(
            projection: projection,
            prompt: threeSupportedLocationChoices(),
            onChoice: { submitted.append($0) }
        )
        let prompt = try #require(controller.prompt)
        #expect(prompt.choices.map(\.isSupported) == [true, true, true])

        // Jump skips index 0 (unknown location) and lands on index 1 (known location) --
        // its exact original array position, never a re-sorted position 0.
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(1))

        // Direct activation of either not-yet-known-location index is rejected outright:
        // no submission, no focus change, no silent promotion.
        #expect(!controller.activatePromptChoice(0))
        #expect(!controller.activatePromptChoice(2))
        #expect(submitted.isEmpty)

        // The one actionable index still submits its own exact original index.
        #expect(controller.activatePromptChoice(1))
        #expect(submitted == [1])
    }
}
