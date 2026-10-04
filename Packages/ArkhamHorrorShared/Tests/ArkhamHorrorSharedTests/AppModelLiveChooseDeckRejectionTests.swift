@testable import ArkhamHorrorShared
import Foundation
import Testing

private struct InstalledLiveChooseDeckPrompt {
    let attempt: LiveGameSessionAttempt
    let projection: BoardProjection
    let connectionID: UUID
}

@MainActor
extension AppModelLiveChooseDeckTests {
    private struct DeckFixture: Decodable {
        let deck: Deck
    }

    private func sampleRejectedDeck() throws -> Deck {
        let url = try #require(
            Bundle.module.url(
                forResource: "decks", withExtension: "json", subdirectory: "Fixtures/Contract"
            )
        )
        return try ContractJSON.decode(DeckFixture.self, from: Data(contentsOf: url)).deck
    }

    private func makeSignedInRejectionModel() async -> AppModel {
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: ScriptedGameLifecycleService()
        )
        model.sessionState = .signedIn(
            profile: .hosted,
            compatibility: .modern(capabilities: []),
            user: .sample
        )
        return model
    }

    private func chooseDeckProjection(
        ownerID: PlayerID,
        rawQuestion: JSONValue = .object(["tag": .string("ChooseDeck")])
    ) -> BoardProjection {
        var questions = UUIDKeyedMap<PlayerIDTag, BasicChoiceQuestionPayload>()
        questions[ownerID] = BasicChoiceQuestionPayload(
            rawValue: rawQuestion,
            state: .updateRequired(tag: "ChooseDeck")
        )
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        return BoardProjection(
            gameName: projection.gameName,
            hasCampaignContext: projection.hasCampaignContext,
            scenario: projection.scenario,
            campaignContinuation: projection.campaignContinuation,
            campaignSummary: projection.campaignSummary,
            acts: projection.acts,
            agendas: projection.agendas,
            locations: projection.locations,
            enemyLocations: projection.enemyLocations,
            investigators: projection.investigators,
            playerOrderCount: projection.playerOrderCount,
            enemyIDs: projection.enemyIDs,
            treacheryIDs: projection.treacheryIDs,
            treacheriesByID: projection.treacheriesByID,
            otherInvestigatorCount: projection.otherInvestigatorCount,
            killedInvestigatorCount: projection.killedInvestigatorCount,
            handCardsByPlayer: projection.handCardsByPlayer,
            orderedHandCardsByPlayer: projection.orderedHandCardsByPlayer,
            inPlayCardsByPlayer: projection.inPlayCardsByPlayer,
            threatTreacheriesByPlayer: projection.threatTreacheriesByPlayer,
            enemiesByLocationID: projection.enemiesByLocationID,
            engagedEnemiesByInvestigatorID: projection.engagedEnemiesByInvestigatorID,
            chaosBag: projection.chaosBag,
            counters: projection.counters,
            skillTest: projection.skillTest,
            questions: questions
        )
    }

    private func installRejectedLivePrompt(
        on model: AppModel,
        gameID: GameID,
        ownerID: PlayerID,
        connection: FakeGameSocketConnection
    ) -> InstalledLiveChooseDeckPrompt {
        let projection = chooseDeckProjection(ownerID: ownerID)
        let attempt = LiveGameSessionAttempt(
            gameID: gameID,
            profile: .hosted,
            attemptID: UUID(),
            sessionGeneration: model.generation,
            credentialEpoch: model.currentCredentialEpoch(for: ServerProfile.hosted.id),
            globalEpoch: model.currentGlobalCredentialEpoch()
        )
        let connectionID = UUID()
        model.liveGameParticipantIdentities[gameID] = .participant(ownerID)
        model.liveGameStates[gameID] = .live(projection)
        model.liveGameSessions[gameID] = LiveGameSessionHandle(
            attemptID: attempt.attemptID,
            task: Task {}
        )
        model.liveGameConnections[gameID] = LiveGameConnectionHandle(
            attemptID: attempt.attemptID,
            connectionID: connectionID,
            connection: connection
        )
        return InstalledLiveChooseDeckPrompt(
            attempt: attempt,
            projection: projection,
            connectionID: connectionID
        )
    }

    @Test("AnswerRejected releases a live deck answer and surfaces the server reason")
    func answerRejectedReleasesLiveDeckAnswer() async throws {
        let model = await makeSignedInRejectionModel()
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let deck = try sampleRejectedDeck()
        let installed = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection
        )
        let promptKey = try #require(model.canAnswerLiveChooseDeck(for: gameID).promptKey)
        let consume = Task {
            await model.consumeLiveGameSocket(
                installed.attempt,
                connection: connection,
                connectionID: installed.connectionID,
                projection: installed.projection
            )
        }
        await connection.waitUntilAwaitingNextEvent()
        await connection.enqueueSendResult(.success(()))

        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))
        #expect(model.liveChooseDeckRejectionReason(for: gameID, promptKey: promptKey) == nil)

        let rejection = Data(
            #"{"tag":"AnswerRejected","reason":"Deck already claimed","questionVersion":null}"#
                .utf8
        )
        await connection.enqueue(.event(.message(rejection)))
        await connection.waitUntilAwaitingNextEvent()

        #expect(model.liveChooseDeckRejectionReason(
            for: gameID,
            promptKey: promptKey
        ) == "Deck already claimed")
        #expect(model.basicChoiceActions[gameID] == nil)
        guard case .canAnswer = model.canAnswerLiveChooseDeck(for: gameID) else {
            Issue.record("A rejected DeckAnswer should leave the ChooseDeck prompt answerable")
            return
        }

        await connection.enqueueSendResult(.success(()))
        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))
        #expect(await connection.sentData.count == 2)
        consume.cancel()
    }

    @Test("GameError is not treated as a correlated live deck rejection")
    func gameErrorDoesNotReleaseLiveDeckAnswerAsRejected() async throws {
        let model = await makeSignedInRejectionModel()
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let deck = try sampleRejectedDeck()
        let installed = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection
        )
        let promptKey = try #require(model.canAnswerLiveChooseDeck(for: gameID).promptKey)
        let consume = Task {
            await model.consumeLiveGameSocket(
                installed.attempt,
                connection: connection,
                connectionID: installed.connectionID,
                projection: installed.projection
            )
        }
        await connection.waitUntilAwaitingNextEvent()
        await connection.enqueueSendResult(.success(()))

        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))
        await connection.enqueue(.event(.message(Data(
            #"{"tag":"GameError","contents":"room-wide error"}"#.utf8
        ))))
        await connection.waitUntilAwaitingNextEvent()

        #expect(model.liveChooseDeckRejectionReason(for: gameID, promptKey: promptKey) == nil)
        #expect(model.basicChoiceActions[gameID]?.phase == .retryable(.outcomeUncertain))
        consume.cancel()
    }
}
