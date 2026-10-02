@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    @Test("Treachery forced ability sends exact source index 0 and question version 68")
    func treacheryForcedAbilitySendsExactAnswer() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try treacheryForcedAbilityEnvelope()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let choice = try #require(prompt.choices.first)
        let projection = try #require(
            model.liveGameState(for: gameID).lastKnownProjection
        )
        #expect(prompt.isChoiceActionable(choice, in: projection))
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: 0)
                == .sentAwaitingSnapshot
        )
        #expect(
            await connection.sentData
                == [treacheryForcedAbilityAnswer()]
        )
    }

    @Test(
        "Treachery forced-ability presentation drift binds generically at all scenario steps",
        arguments: [37, 68]
    )
    func treacheryForcedAbilityPresentationDriftBindsGenerically(
        questionVersion: Int
    ) throws {
        let envelope = try semanticEnvelope(
            rawFixture: "question-treachery-forced-ability",
            presentationFixture: "question-presentation-treachery-forced-ability",
            questionVersion: questionVersion,
            mutatePresentation: { presentation in
                try Self.replaceFirstPresentationChoiceField(
                    in: &presentation,
                    key: "actorId",
                    value: .string("c02001")
                )
            }
        )
        let playerID = try #require(envelope.playerID)
        let payload = try #require(envelope.game.question[playerID])
        let binding = try #require(payload.presentation)
        #expect(binding.descriptor(forSourceIndex: 0)?.actorID == "c02001")
        #expect(!payload.isUpdateRequired)
        #expect(envelope.game.name.isEmpty == false)
    }

    @Test("Treachery-containing prompts render and submit generically")
    func treacheryContainingPromptUsesGenericPathInAppModel() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-treachery-forced-ability",
            presentationFixture: "question-presentation-treachery-forced-ability",
            questionVersion: 68,
            mutateRawQuestion: { rawQuestion in
                guard case var .object(rawObject) = rawQuestion else {
                    throw SemanticFixtureError.unexpectedShape
                }
                rawObject["tag"] = .string("ChooseOne")
                rawQuestion = .object(rawObject)
            },
            mutatePresentation: { presentation in
                presentation["questionKind"] = .string("chooseOne")
            }
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
        let projection = try #require(model.liveGameState(for: gameID).lastKnownProjection)
        let choice = try #require(prompt.choices.first)
        #expect(prompt.readOnlyReason == nil)
        #expect(prompt.isRenderableQuestion)
        #expect(prompt.canSubmit)
        #expect(prompt.isChoiceActionable(choice, in: projection))
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: choice.index)
                == .sentAwaitingSnapshot
        )
        #expect(await connection.sentData == [treacheryForcedAbilityAnswer()])
    }

    @Test("Treachery forced ability trusts the server descriptor before sending")
    func treacheryForcedAbilityTrustsServerDescriptorBeforeSend() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try treacheryForcedAbilityEnvelope()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )
        let identity = try #require(
            model.basicChoicePresentation(for: gameID)?.identity
        )

        let withoutTreachery = try semanticEnvelope(
            rawFixture: "question-treachery-forced-ability",
            presentationFixture: "question-presentation-treachery-forced-ability",
            questionVersion: 68
        )
        model.liveGameStates[gameID] = .live(
            BoardProjectionBuilder.makeProjection(
                from: withoutTreachery.game
            )
        )

        #expect(
            await model.submitBasicChoice(identity, choiceIndex: 0)
                == .sentAwaitingSnapshot
        )
        #expect(await connection.sentData == [treacheryForcedAbilityAnswer()])
    }

    private func treacheryForcedAbilityEnvelope() throws -> GetGameEnvelope {
        try semanticEnvelope(
            rawFixture: "question-treachery-forced-ability",
            presentationFixture: "question-presentation-treachery-forced-ability",
            questionVersion: 68,
            mutateGame: { game in
                game["treacheries"] = .object([
                    treacheryForcedAbilityFixtureID: .object([
                        "id": .string(treacheryForcedAbilityFixtureID),
                        "cardCode": .string("c01007"),
                        "tokens": .array([]),
                    ]),
                ])
            }
        )
    }

    private static func replaceFirstPresentationChoiceField(
        in presentation: inout [String: JSONValue],
        key: String,
        value: JSONValue
    ) throws {
        guard case var .array(choices)? = presentation["choices"],
              case var .object(choice)? = choices.first
        else { throw SemanticFixtureError.unexpectedShape }
        choice[key] = value
        choices[0] = .object(choice)
        presentation["choices"] = .array(choices)
    }

    private func treacheryForcedAbilityAnswer() -> Data {
        Data(
            """
            {"contents":{"choice":0,\
            "playerId":"00000000-0000-0000-0000-000000000001",\
            "questionVersion":68},"tag":"Answer"}
            """.utf8
        )
    }
}
