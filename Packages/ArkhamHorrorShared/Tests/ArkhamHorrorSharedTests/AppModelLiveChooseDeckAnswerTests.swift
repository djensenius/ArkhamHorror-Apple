@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
extension AppModelLiveChooseDeckTests {
    @Test("DeckAnswer is sent for a QuestionLabel-wrapped live ChooseDeck prompt")
    func sendsDeckAnswerForLabeledDreamEatersChooseDeckPrompt() async throws {
        let service = ScriptedGameLifecycleService()
        let model = await makeSignedInModel(service: service)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let deck = try sampleDeck()
        let rawQuestion = try dreamEatersPartAChooseDeckQuestion()
        await connection.enqueueSendResult(.success(()))
        installLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            participant: .participant(ownerID),
            rawQuestion: rawQuestion,
            connection: connection
        )

        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))

        let sent = try #require(await connection.sentData.first)
        let decoded = try ContractJSON.decode(DeckAnswer.self, from: sent)
        #expect(decoded == DeckAnswer(deckId: deck.id, playerId: ownerID))
    }

    @Test("DeckAnswer is refused for spectators, other players, and wrong question shapes")
    func refusesUnauthorizedLiveDeckAnswers() async throws {
        let deck = try sampleDeck()
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let cases: [(LiveGameParticipantIdentity, JSONValue)] = [
            (.spectator, .object(["tag": .string("ChooseDeck")])),
            (.participant(PlayerID(UUID())), .object(["tag": .string("ChooseDeck")])),
            (.participant(ownerID), .object(["tag": .string("ChooseJoinDeck")])),
            (.participant(ownerID), .object([
                "card": .null,
                "label": .string("$theDreamEaters.question.chooseDeckForPartA"),
                "question": .object(["tag": .string("ChooseJoinDeck")]),
                "tag": .string("QuestionLabel"),
            ])),
        ]
        for (participant, rawQuestion) in cases {
            let model = await makeSignedInModel(service: ScriptedGameLifecycleService())
            let connection = FakeGameSocketConnection()
            let gameID = GameID(UUID())
            installLivePrompt(
                on: model,
                gameID: gameID,
                ownerID: ownerID,
                participant: participant,
                rawQuestion: rawQuestion,
                connection: connection
            )

            #expect(await !(model.chooseDeckForLivePrompt(deck, in: gameID)))
            #expect(await connection.sentData.isEmpty)
        }
    }

    @Test("DeckAnswer is refused for legacy servers and missing live connections")
    func refusesLegacyAndDisconnectedPrompts() async throws {
        let deck = try sampleDeck()
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))

        let legacyModel = await GameLifecycleTestModel.makeSignedIn(
            gameService: ScriptedGameLifecycleService()
        )
        let legacyConnection = FakeGameSocketConnection()
        let legacyGameID = GameID(UUID())
        installLivePrompt(
            on: legacyModel,
            gameID: legacyGameID,
            ownerID: ownerID,
            participant: .participant(ownerID),
            connection: legacyConnection
        )
        #expect(await !(legacyModel.chooseDeckForLivePrompt(deck, in: legacyGameID)))
        #expect(await legacyConnection.sentData.isEmpty)

        let disconnectedModel = await makeSignedInModel(service: ScriptedGameLifecycleService())
        let disconnectedConnection = FakeGameSocketConnection()
        let disconnectedGameID = GameID(UUID())
        installLivePrompt(
            on: disconnectedModel,
            gameID: disconnectedGameID,
            ownerID: ownerID,
            participant: .participant(ownerID),
            connection: disconnectedConnection
        )
        disconnectedModel.liveGameConnections[disconnectedGameID] = nil
        #expect(await !(disconnectedModel.chooseDeckForLivePrompt(deck, in: disconnectedGameID)))
        #expect(await disconnectedConnection.sentData.isEmpty)
    }

    @Test("Live deck picker heading uses the resolved Dream-Eaters QuestionLabel")
    func liveDeckPickerHeadingUsesResolvedDreamEatersQuestionLabel() async throws {
        let documents = try dreamEatersLabelCatalogDocuments()
        let service = ScriptedGameLifecycleService()
        let model = await makeSignedInModel(service: service)
        model.localeCatalog = try await documents.loadSnapshot()
        model.localeCatalogRequest = LocaleCatalogRequest(
            profileID: model.selectedProfile.id,
            advertisement: documents.advertisement
        )
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let rawQuestion = try dreamEatersPartAChooseDeckQuestion()
        let presentation = try dreamEatersPartAChooseDeckPresentation()
        let binding = try presentation.bind(to: rawQuestion, expectedQuestionVersion: 10)
        installLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            participant: .participant(ownerID),
            rawQuestion: rawQuestion,
            presentation: binding,
            connection: FakeGameSocketConnection()
        )

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(prompt.promptLabelResolutions["questionLabel"] == .resolved(
            "Choose Deck For Part A"
        ))
        #expect(prompt.liveChooseDeckPickerHeading == "Choose Deck For Part A")
    }

    @Test("Live deck picker heading uses German semantic fallback")
    func liveDeckPickerHeadingUsesGermanSemanticLocaleWhenQuestionLabelIsUnresolved() throws {
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let rawQuestion = JSONValue.object(["tag": .string("ChooseDeck")])
        let prompt = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: gameID,
                ownerID: ownerID,
                questionVersion: 10,
                rawQuestion: rawQuestion,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: .updateRequired(tag: "ChooseDeck"),
            semanticLocaleIdentifier: "de",
            promptLabelResolutions: ["questionLabel": .unavailable(.missingKey)],
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )

        #expect(prompt.liveChooseDeckPickerHeading == "Deck wählen")
    }

    @Test("Live deck picker heading falls back when the QuestionLabel is unresolved")
    func liveDeckPickerHeadingFallsBackWhenQuestionLabelIsUnresolved() async throws {
        let service = ScriptedGameLifecycleService()
        let model = await makeSignedInModel(service: service)
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let rawQuestion = try dreamEatersPartAChooseDeckQuestion()
        let presentation = try dreamEatersPartAChooseDeckPresentation()
        let binding = try presentation.bind(to: rawQuestion, expectedQuestionVersion: 10)
        installLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            participant: .participant(ownerID),
            rawQuestion: rawQuestion,
            presentation: binding,
            connection: FakeGameSocketConnection()
        )

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(prompt.promptLabelResolutions["questionLabel"]?.title == nil)
        #expect(
            prompt.liveChooseDeckPickerHeading ==
                BasicChoicePromptPresentation.liveChooseDeckGenericHeading()
        )
        #expect(!prompt.liveChooseDeckPickerHeading.contains("$"))
    }
}
