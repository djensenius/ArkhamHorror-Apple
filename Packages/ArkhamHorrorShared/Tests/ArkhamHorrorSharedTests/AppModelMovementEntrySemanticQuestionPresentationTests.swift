@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    @Test("Q36 sends exact Cellar source index 9 and question version 36")
    func q36SemanticCellarMoveSendsExactAnswer() async throws {
        try await assertMovementAnswer(choiceIndex: 9)
    }

    @Test("Q36 sends exact Attic source index 10 and question version 36")
    func q36SemanticAtticMoveSendsExactAnswer() async throws {
        try await assertMovementAnswer(choiceIndex: 10)
    }

    @Test("Q37 sends exact forced-ability source index 0 and question version 37")
    func q37SemanticForcedAbilitySendsExactAnswer() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-gathering-cellar-entry-forced",
            presentationFixture: "question-presentation-gathering-cellar-entry-forced",
            questionVersion: 37,
            mutateGame: {
                try addGatheringLocations(
                    to: &$0,
                    includeAttic: false
                )
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
                == [expectedAnswer(choiceIndex: 0, questionVersion: 37)]
        )
    }

    @Test("Q38 sends exact Cellar damage source index 0 and question version 38")
    func q38SemanticDamageAssignmentSendsExactAnswer() async throws {
        try await assertAssignmentAnswer(
            rawFixture: "question-gathering-cellar-damage-assignment",
            presentationFixture: "question-presentation-gathering-cellar-damage-assignment"
        )
    }

    @Test("Q38 sends exact Attic horror source index 0 and question version 38")
    func q38SemanticHorrorAssignmentSendsExactAnswer() async throws {
        try await assertAssignmentAnswer(
            rawFixture: "question-gathering-attic-horror-assignment",
            presentationFixture: "question-presentation-gathering-attic-horror-assignment"
        )
    }

    @Test("The newest projection rejects movement after its destination disappears")
    func semanticMovementRevalidatesBeforeSend() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-gathering-movement",
            presentationFixture: "question-presentation-gathering-movement",
            questionVersion: 36,
            mutateGame: { try addGatheringLocations(to: &$0) }
        )
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

        let withoutCellar = try semanticEnvelope(
            rawFixture: "question-gathering-movement",
            presentationFixture: "question-presentation-gathering-movement",
            questionVersion: 36,
            mutateGame: {
                try addGatheringLocations(
                    to: &$0,
                    includeCellar: false
                )
            }
        )
        model.liveGameStates[gameID] = .live(
            BoardProjectionBuilder.makeProjection(from: withoutCellar.game)
        )

        #expect(
            await model.submitBasicChoice(identity, choiceIndex: 9)
                == .unsupportedChoice
        )
        #expect(await connection.sentData.isEmpty)
    }

    private func assertMovementAnswer(choiceIndex: Int) async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: "question-gathering-movement",
            presentationFixture: "question-presentation-gathering-movement",
            questionVersion: 36,
            mutateGame: { try addGatheringLocations(to: &$0) }
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
        let choice = try #require(
            prompt.choices.first { $0.index == choiceIndex }
        )
        let projection = try #require(
            model.liveGameState(for: gameID).lastKnownProjection
        )
        #expect(prompt.isChoiceActionable(choice, in: projection))
        #expect(
            await model.submitBasicChoice(
                prompt.identity,
                choiceIndex: choiceIndex
            ) == .sentAwaitingSnapshot
        )
        #expect(
            await connection.sentData
                == [expectedAnswer(
                    choiceIndex: choiceIndex,
                    questionVersion: 36
                )]
        )
    }

    private func assertAssignmentAnswer(
        rawFixture: String,
        presentationFixture: String
    ) async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try semanticEnvelope(
            rawFixture: rawFixture,
            presentationFixture: presentationFixture,
            questionVersion: 38
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
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: 0)
                == .sentAwaitingSnapshot
        )
        #expect(
            await connection.sentData
                == [expectedAnswer(choiceIndex: 0, questionVersion: 38)]
        )
    }

    private func expectedAnswer(
        choiceIndex: Int,
        questionVersion: Int
    ) -> Data {
        let prefix = #"{"contents":{"choice":"#
        let player = #","playerId":"00000000-0000-0000-0000-000000000001","questionVersion":"#
        let suffix = #"},"tag":"Answer"}"#
        return Data(
            "\(prefix)\(choiceIndex)\(player)\(questionVersion)\(suffix)".utf8
        )
    }

    private func addGatheringLocations(
        to game: inout [String: JSONValue],
        includeCellar: Bool = true,
        includeAttic: Bool = true
    ) throws {
        guard case var .object(locations)? = game["locations"],
              case let .object(template)? = locations.values.first
        else {
            throw SemanticFixtureError.unexpectedShape
        }

        func addLocation(id: String, cardCode: String, label: String) {
            var location = template
            location["id"] = .string(id)
            location["cardCode"] = .string(cardCode)
            location["label"] = .string(label)
            location["investigators"] = .array([])
            locations[id] = .object(location)
        }

        if includeCellar {
            addLocation(
                id: "a3497b9f-796b-406d-aeb4-9b96fa9f4905",
                cardCode: "c01114",
                label: "Cellar"
            )
        }
        if includeAttic {
            addLocation(
                id: "dbaa2d2e-4ceb-44b2-a554-e5fa370e7882",
                cardCode: "c01113",
                label: "Attic"
            )
        }
        game["locations"] = .object(locations)
    }
}
