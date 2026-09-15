@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Basic choice semantic presentation")
struct BasicChoiceSemanticPresentationTests {
    @Test("Q34 renders and submits source index 12 through generic advanceAct")
    func q34AdvanceActUsesGenericPath() throws {
        let prompt = try prompt(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective"
        )
        let projection = try gatheringProductionProjection()
        let choice = try #require(prompt.choices.first { $0.index == 12 })

        #expect(prompt.choices.map(\.index) == Array(0 ... 12))
        #expect(!choice.isSupported)
        #expect(
            prompt.displayTitle(for: choice, in: projection)
                == "Advance act (2 clues per investigator from anywhere)"
        )
        #expect(prompt.systemImage(for: choice) == "arrow.up.circle.fill")
        #expect(prompt.isChoiceActionable(choice, in: projection))

        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onChoice: { submitted.append($0) }
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        let actionableSourceIndices = prompt.choices.compactMap {
            prompt.isChoiceActionable($0, in: projection) ? $0.index : nil
        }
        #expect(actionableSourceIndices.first == 0)
        #expect(actionableSourceIndices.last == 12)
        for sourceIndex in actionableSourceIndices.dropFirst() {
            #expect(controller.handle(.command(.focusMove(.down))))
            #expect(
                controller.coordinator.currentFocus ==
                    BoardFocusID.promptChoice(sourceIndex)
            )
        }
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [12])
    }

    @Test("Q35 focuses and submits source index 0 through the same advanceAct path")
    func q35AdvanceActUsesGenericPath() throws {
        let prompt = try prompt(
            rawFixture: "question-gathering-act-advance",
            presentationFixture: "question-presentation-gathering-act-advance"
        )
        let projection = gatheringProjection(includeAct: true, includeInvestigator: false)
        let choice = try #require(prompt.choices.first)

        #expect(prompt.questionVersion == 35)
        #expect(choice.index == 0)
        #expect(!choice.isSupported)
        #expect(prompt.displayTitle(for: choice, in: projection) == "Advance act")
        #expect(prompt.isChoiceActionable(choice, in: projection))

        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onChoice: { submitted.append($0) }
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0])
    }

    @Test("advanceAct re-resolves act and optional actor against the newest projection")
    func advanceActFailsClosedWhenIdentityDisappears() throws {
        let q34 = try prompt(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective"
        )
        let choice = try #require(q34.choices.first { $0.index == 12 })
        #expect(
            !q34.isChoiceActionable(
                choice,
                in: gatheringProjection(includeAct: false, includeInvestigator: true)
            )
        )
        #expect(
            !q34.isChoiceActionable(
                choice,
                in: gatheringProjection(includeAct: true, includeInvestigator: false)
            )
        )

        let q35 = try prompt(
            rawFixture: "question-gathering-act-advance",
            presentationFixture: "question-presentation-gathering-act-advance"
        )
        let confirmation = try #require(q35.choices.first)
        #expect(
            !q35.isChoiceActionable(
                confirmation,
                in: gatheringProjection(includeAct: false, includeInvestigator: false)
            )
        )
    }

    @Test("A missing semantic descriptor never falls back to raw actionability")
    func missingDescriptorDoesNotSynthesizeAction() throws {
        let raw = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: Data(
                """
                {"tag":"ChooseOne","choices":[
                  {"tag":"EndTurnButton","investigatorId":"c01001","messages":[]}
                ]}
                """.utf8
            )
        )
        let semantic = QuestionPresentation(
            protocolVersion: 1,
            questionVersion: 3,
            questionKind: .chooseOne,
            choiceCount: 1,
            choices: []
        )
        let bound = try semantic.bind(
            to: raw.rawValue,
            expectedQuestionVersion: 3
        )
        let prompt = makePrompt(payload: raw, presentation: bound)
        let projection = gatheringProjection(includeAct: false, includeInvestigator: true)
        let choice = try #require(prompt.choices.first)

        #expect(choice.isSupported)
        #expect(!prompt.isChoiceActionable(choice, in: projection))
        #expect(
            prompt.displayTitle(for: choice, in: projection)
                == "Unavailable action (choice 1)"
        )
        #expect(
            prompt.accessibilityHint(for: choice, in: projection)
                == "This choice has no semantic description and cannot be activated."
        )

        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onChoice: { submitted.append($0) }
        )
        #expect(!controller.activatePromptChoice(0))
        #expect(submitted.isEmpty)
    }

    @Test("Changed semantic metadata changes prompt identity with raw bytes/version unchanged")
    func semanticMetadataParticipatesInIdentity() throws {
        let payload = try rawPayload("question-gathering-act-advance")
        let original = try presentation("question-presentation-gathering-act-advance")
        let changed = QuestionPresentation(
            protocolVersion: original.protocolVersion,
            questionVersion: original.questionVersion,
            questionKind: original.questionKind,
            choiceCount: original.choiceCount,
            choices: [
                .init(
                    sourceIndex: 0,
                    kind: .advanceAct,
                    actorID: nil,
                    entity: .init(kind: .act, id: "c01109"),
                    label: nil,
                    ability: nil,
                    cost: nil
                ),
            ]
        )
        let first = identity(raw: payload.rawValue, presentation: original, version: 35)
        let second = identity(raw: payload.rawValue, presentation: changed, version: 35)
        #expect(first != second)
        #expect(first.promptKey != second.promptKey)
    }

    private func prompt(
        rawFixture: String,
        presentationFixture: String
    ) throws -> BasicChoicePromptPresentation {
        let payload = try rawPayload(rawFixture)
        let presentation = try presentation(presentationFixture)
        let bound = try presentation.bind(
            to: payload.rawValue,
            expectedQuestionVersion: presentation.questionVersion
        )
        return makePrompt(payload: payload, presentation: bound)
    }

    func makePrompt(
        payload: BasicChoiceQuestionPayload,
        presentation: BoundQuestionPresentation,
        choiceLabelResolutions: [Int: BasicChoiceLabelResolution]? = nil
    ) -> BasicChoicePromptPresentation {
        BasicChoicePromptPresentation(
            identity: identity(
                raw: payload.rawValue,
                presentation: presentation.presentation,
                version: presentation.presentation.questionVersion
            ),
            question: payload.state,
            semanticPresentation: presentation,
            choiceLabelResolutions: choiceLabelResolutions,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private func identity(
        raw: JSONValue,
        presentation: QuestionPresentation,
        version: Int
    ) -> BasicChoicePromptIdentity {
        BasicChoicePromptIdentity(
            gameID: BoardTestFixtures.gameID(),
            ownerID: BoardTestFixtures.playerID(),
            questionVersion: version,
            rawQuestion: raw,
            questionPresentation: presentation,
            sessionAttemptID: nil,
            connectionID: nil
        )
    }

    func gatheringProjection(
        includeAct: Bool,
        includeInvestigator: Bool
    ) -> BoardProjection {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let actID = BoardTestFixtures.actID("c01108")
        return BoardProjectionBuilder.makeProjection(
            from: BoardTestFixtures.snapshot(
                investigators: includeInvestigator
                    ? [investigatorID: BoardTestFixtures.investigator(id: investigatorID)]
                    : [:],
                acts: includeAct ? [actID: BoardTestFixtures.act(id: actID)] : [:],
                activeInvestigatorID: investigatorID,
                leadInvestigatorID: investigatorID
            )
        )
    }

    func rawPayload(_ name: String) throws -> BasicChoiceQuestionPayload {
        try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: fixture(name))
    }

    private func presentation(_ name: String) throws -> QuestionPresentation {
        try ContractJSON.decode(QuestionPresentation.self, from: fixture(name))
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }
}

private extension BasicChoiceSemanticPresentationTests {
    func gatheringProductionProjection() throws -> BoardProjection {
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: fixture("get-game")
        )
        return BoardProjectionBuilder.makeProjection(from: envelope.game)
    }
}
