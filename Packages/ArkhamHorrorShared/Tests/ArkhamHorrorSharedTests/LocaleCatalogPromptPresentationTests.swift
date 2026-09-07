@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Locale catalog prompt presentation")
struct LocaleCatalogPromptPresentationTests {
    private func question() throws -> BasicChoiceQuestionState {
        try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: Data(
                """
                {"tag":"Read","flavorText":{"title":"$story.title","body":[\
                {"tag":"I18nEntry","key":"story.body","variables":{}}]},\
                "readChoices":{"tag":"BasicReadChoices","contents":[\
                {"tag":"Label","label":"$continue","messages":[]}]},"readCards":null}
                """.utf8
            )
        ).state
    }

    private func prompt(
        _ question: BasicChoiceQuestionState, resolution: StoryResolution
    ) -> BasicChoicePromptPresentation {
        BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 7,
                rawQuestion: .object([:]),
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: question,
            storyResolution: resolution,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    @Test("Availability gates focus, controller dispatch, and accessibility without reindexing")
    func promptAvailabilityDrivesEveryInteractiveSurface() throws {
        let state = try question()
        let resolved = StoryResolution.resolved(ResolvedStory(
            title: "Synthetic title",
            body: [.nodes([.paragraph([.text("Synthetic body")])])]
        ))
        let unavailable = StoryResolution.unavailable(.missingKey)
        let availablePrompt = prompt(state, resolution: resolved)
        let unavailablePrompt = prompt(state, resolution: unavailable)
        #expect(availablePrompt.choices.map(\.index) == unavailablePrompt.choices.map(\.index))
        #expect(availablePrompt.canSubmit)
        #expect(!unavailablePrompt.canSubmit)

        var submitted: [Int] = []
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let controller = BoardCommandController(
            projection: projection,
            prompt: availablePrompt,
            onChoice: { submitted.append($0) }
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.activatePromptChoice(0))
        #expect(submitted == [0])

        controller.applyPrompt(unavailablePrompt)
        #expect(!controller.handle(.command(.jumpToActivePrompt)))
        #expect(!controller.activatePromptChoice(0))
        #expect(submitted == [0])
        #expect(
            BoardDisplayFormatting.choiceAccessibilityHint(
                for: unavailablePrompt.choices[0],
                in: projection,
                storyResolution: unavailable,
                canSubmit: unavailablePrompt.canSubmit,
                statusMessage: unavailablePrompt.statusMessage
            ) == StoryUnavailableReason.missingKey.announcement
        )
    }

    @Test("Catalog retry is a distinct focusable action and permanent failures expose none")
    // swiftlint:disable:next function_body_length
    func catalogRetryUsesItsOwnControllerPath() throws {
        let state = try question()
        let retry = BasicChoiceCatalogRetryPresentation(
            profileID: UUID(),
            catalogGeneration: 4,
            promptKey: BasicChoicePromptKey(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 7,
                rawQuestion: .object([:])
            )
        )
        let transient = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: retry.promptKey.gameID,
                ownerID: retry.promptKey.ownerID,
                questionVersion: retry.promptKey.questionVersion,
                rawQuestion: retry.promptKey.rawQuestion,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: state,
            storyResolution: .unavailable(.catalog(.transportFailure)),
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil,
            catalogRetry: retry
        )
        let permanent = BasicChoicePromptPresentation(
            identity: transient.identity,
            question: state,
            storyResolution: .unavailable(.catalog(.manifestDigestMismatch)),
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        var activated: [BasicChoiceCatalogRetryPresentation] = []
        let controller = BoardCommandController(
            projection: BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot()),
            prompt: transient,
            onCatalogRetry: { activated.append($0) }
        )
        #expect(transient.canRetryCatalog)
        #expect(!transient.canRetry)
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptCatalogRetry)
        #expect(controller.handle(.command(.primaryAction)))
        #expect(activated == [retry])

        controller.applyPrompt(permanent)
        #expect(!permanent.canRetryCatalog)
        #expect(!controller.activatePromptCatalogRetry())
        #expect(!controller.handle(
            focusID: BoardFocusID.promptCatalogRetry,
            .command(.primaryAction)
        ))
        #expect(activated == [retry])
    }

    @Test("Story flow keeps inline fragments together and speaks localized card names")
    func storyFlowAndAccessibilityPreserveNarrative() {
        let inline: [StoryNode] = [
            .text("Move "),
            .emphasis(.bold, [.text("2")]),
            .text(" clues to "),
            .cardReference(code: "01001", children: [.text("Roland Banks")]),
            .text("."),
        ]
        let paragraph = StoryNode.paragraph([.text("Next paragraph.")])
        #expect(StoryNodePresentation.flow(inline + [paragraph]) == [
            .inline(inline),
            .block(paragraph),
        ])
        #expect(
            StoryNodePresentation.accessibilityLabel(
                for: [.cardReference(code: "01001", children: [.text("Roland Banks")])]
            ) == "Roland Banks"
        )
    }
}
