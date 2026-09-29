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
