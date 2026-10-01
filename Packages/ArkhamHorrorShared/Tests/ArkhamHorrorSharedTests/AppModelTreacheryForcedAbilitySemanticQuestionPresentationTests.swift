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
        "Treachery forced-ability presentation drift fails closed at all scenario steps",
        arguments: [37, 68]
    )
    func treacheryForcedAbilityPresentationDriftBecomesUpdateRequired(
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
        #expect(payload.presentation == nil)
        #expect(payload.isUpdateRequired)
        #expect(envelope.game.name.isEmpty == false)
    }

    @Test("Unsealed treachery-containing prompts require an app update")
    func unsealedTreacheryContainingPromptRequiresUpdateInAppModel() async throws {
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
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameState(for: gameID).lastKnownProjection)
        let choice = try #require(prompt.choices.first)
        #expect(prompt.readOnlyReason == .updateRequired)
        #expect(!prompt.isRenderableQuestion)
        #expect(!prompt.canSubmit)
        #expect(!prompt.isChoiceActionable(choice, in: projection))
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: choice.index)
                == .readOnly
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Treachery forced ability revalidates the latest snapshot before sending")
    func treacheryForcedAbilityRejectsStaleSource() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try treacheryForcedAbilityEnvelope()
        let connection = FakeGameSocketConnection()
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
                == .unsupportedChoice
        )
        #expect(await connection.sentData.isEmpty)
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
