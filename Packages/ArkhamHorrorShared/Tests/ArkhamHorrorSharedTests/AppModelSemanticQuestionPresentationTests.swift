@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    @Test("Q34 sends exact source index 12 and question version 34")
    func q34SemanticAdvanceActSendsExactAnswer() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 34
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let choice = try #require(prompt.choices.first { $0.index == 12 })
        let projection = try #require(
            model.liveGameState(for: gameID).lastKnownProjection
        )
        assertLegacyActionabilityParity(prompt: prompt, projection: projection)
        #expect(prompt.questionVersion == 34)
        #expect(prompt.isChoiceActionable(
            choice,
            in: projection
        ))
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: 12)
                == .sentAwaitingSnapshot
        )
        // swiftlint:disable:next line_length
        #expect(await connection.sentData == [Data(#"{"contents":{"choice":12,"playerId":"00000000-0000-0000-0000-000000000001","questionVersion":34},"tag":"Answer"}"#.utf8)])
    }

    @Test("Q35 sends exact source index 0 and question version 35")
    func q35SemanticAdvanceActSendsExactAnswer() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-gathering-act-advance",
            presentationFixture: "question-presentation-gathering-act-advance",
            questionVersion: 35
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(prompt.questionVersion == 35)
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: 0)
                == .sentAwaitingSnapshot
        )
        // swiftlint:disable:next line_length
        #expect(await connection.sentData == [Data(#"{"contents":{"choice":0,"playerId":"00000000-0000-0000-0000-000000000001","questionVersion":35},"tag":"Answer"}"#.utf8)])
    }

    @Test("The newest projection rejects advanceAct after its act disappears")
    func semanticAdvanceActRevalidatesBeforeSend() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 34
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)

        let withoutAct = try semanticEnvelope(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 34,
            mutateGame: { $0["acts"] = .object([:]) }
        )
        model.liveGameStates[gameID] = .live(
            BoardProjectionBuilder.makeProjection(from: withoutAct.game)
        )

        #expect(
            await model.submitBasicChoice(identity, choiceIndex: 12)
                == .unsupportedChoice
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Same raw question/version with changed descriptors rejects the stale identity")
    func changedSemanticDescriptorIsStale() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 33,
            mutatePresentation: { presentation in
                guard case var .array(choices)? = presentation["choices"],
                      choices.indices.contains(12)
                else { throw SemanticFixtureError.unexpectedShape }
                choices.remove(at: 12)
                presentation["choices"] = .array(choices)
            }
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )
        let stale = try #require(model.basicChoicePresentation(for: gameID)?.identity)

        let changed = try semanticEnvelope(
            rawFixture: "question-gathering-act-objective",
            presentationFixture: "question-presentation-gathering-act-objective",
            questionVersion: 33,
            mutatePresentation: { presentation in
                guard case var .array(choices)? = presentation["choices"],
                      choices.indices.contains(12),
                      case var .object(choice) = choices[0]
                else { throw SemanticFixtureError.unexpectedShape }
                choice["actorId"] = .string("c01002")
                choices[0] = .object(choice)
                choices.remove(at: 12)
                presentation["choices"] = .array(choices)
            }
        )
        model.liveGameStates[gameID] = .live(
            BoardProjectionBuilder.makeProjection(from: changed.game)
        )
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.identity.promptKey != stale.promptKey)
        #expect(
            await model.submitBasicChoice(stale, choiceIndex: 12)
                == .staleQuestion
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Semantic localized labels are collected by authoritative source index")
    func semanticLocalizedLabelUsesDescriptorIndex() async throws {
        let (model, _) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: fixtureData(named: "question-gathering-act-objective")
        )
        let presentation = QuestionPresentation(
            protocolVersion: 1,
            questionVersion: 33,
            questionKind: .playerWindowChooseOne,
            choiceCount: 13,
            choices: [
                .init(
                    sourceIndex: 12,
                    kind: .localizedLabel,
                    actorID: nil,
                    entity: nil,
                    label: .init(kind: .embeddedI18n, text: "$continue"),
                    ability: nil,
                    cost: nil
                ),
            ]
        )
        let bound = try presentation.bind(
            to: payload.rawValue,
            expectedQuestionVersion: 33
        )

        #expect(model.choiceLabelResolutions(
            for: payload.supportedQuestion,
            semanticPresentation: bound
        ) == [12: .resolved("Continue")])
    }

    @Test("An explicit unsupported semantic kind still requires an app update")
    func unsupportedSemanticKindFailsClosed() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-gathering-act-advance",
            presentationFixture: "question-presentation-gathering-act-advance",
            questionVersion: 35,
            mutateRawQuestion: { rawQuestion in
                rawQuestion = .object(["tag": .string("FutureQuestion")])
            },
            mutatePresentation: { presentation in
                presentation["questionKind"] = .string("unsupported")
                presentation["choiceCount"] = .number(.integer(0))
                presentation["choices"] = .array([])
            }
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(prompt.readOnlyReason == .updateRequired)
        #expect(!prompt.isRenderableQuestion)
        #expect(prompt.choices.isEmpty)
        #expect(!prompt.canSubmit)
    }

    private enum SemanticFixtureError: Error {
        case unexpectedShape
    }

    private func assertLegacyActionabilityParity(
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection
    ) {
        let legacy = BasicChoicePromptPresentation(
            identity: prompt.identity,
            question: prompt.question,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        let semanticActionability = prompt.choices.map {
            prompt.isChoiceActionable($0, in: projection)
        }
        let legacyActionability = legacy.choices.map {
            legacy.isChoiceActionable($0, in: projection)
        }
        #expect(
            Array(semanticActionability.prefix(12))
                == Array(legacyActionability.prefix(12))
        )
        #expect(semanticActionability[12])
        #expect(!legacyActionability[12])
    }

    private func semanticEnvelope(
        rawFixture: String,
        presentationFixture: String,
        questionVersion: Int,
        mutateRawQuestion: ((inout JSONValue) throws -> Void)? = nil,
        mutateGame: ((inout [String: JSONValue]) throws -> Void)? = nil,
        mutatePresentation: ((inout [String: JSONValue]) throws -> Void)? = nil
    ) throws -> GetGameEnvelope {
        var envelope = try ContractJSON.decode(
            JSONValue.self,
            from: fixtureData(named: "get-game")
        )
        guard case var .object(root) = envelope,
              case var .object(game)? = root["game"],
              case let .string(playerID)? = root["playerId"]
        else {
            throw SemanticFixtureError.unexpectedShape
        }
        var presentation = try fixtureJSON(presentationFixture)
        guard case var .object(presentationObject) = presentation else {
            throw SemanticFixtureError.unexpectedShape
        }
        presentationObject["questionVersion"] = .number(.integer(Int64(questionVersion)))
        try mutatePresentation?(&presentationObject)
        presentation = .object(presentationObject)
        var rawQuestion = try fixtureJSON(rawFixture)
        try mutateRawQuestion?(&rawQuestion)
        game["question"] = .object([
            playerID: rawQuestion,
        ])
        game["questionPresentation"] = .object([
            playerID: presentation,
        ])
        game["scenarioSteps"] = .number(.integer(Int64(questionVersion)))
        try mutateGame?(&game)
        root["game"] = .object(game)
        envelope = .object(root)
        return try ContractJSON.decode(
            GetGameEnvelope.self,
            from: ContractJSON.encode(envelope)
        )
    }

    private func fixtureJSON(_ name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixtureData(named: name))
    }
}
