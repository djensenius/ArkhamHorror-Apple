@testable import ArkhamHorrorShared
import Foundation
import Testing

private struct MulliganPreferredLanguages: PreferredLanguagesProviding {
    let preferredLanguages = ["en"]
}

private struct MulliganSession {
    let model: AppModel
    let connection: FakeGameSocketConnection
    let gameID: GameID
    let envelope: GetGameEnvelope
    let questionVersion: Int
}

extension AppModelLiveGameTests {
    private static let mulliganCardCodes = [
        "00000000-0000-0000-0000-0000000003c0": "c01018",
        "00000000-0000-0000-0000-0000000003c1": "c01023",
        "00000000-0000-0000-0000-0000000003c2": "c01030",
    ]

    private func mulliganCatalogDocuments() throws -> SyntheticLocaleCatalogDocuments {
        try SyntheticLocaleCatalogDocuments.make(
            pack: "core",
            entryKeys: ["label.doneWithMulligan"],
            chunkEntries: """
            {"label.doneWithMulligan":{"form":"message","nodes":[\
            {"type":"text","value":"Done replacing cards"}],"variables":[]}}
            """
        )
    }

    private func makeMulliganModel(
        documents: SyntheticLocaleCatalogDocuments,
        loader: LocaleCatalogLoader
    ) -> (model: AppModel, fakes: Fakes) {
        let tokenStore = FakeTokenStore(tokens: [documents.profile.id: "catalog-token"])
        let service = ScriptedGameLifecycleService()
        let socketFactory = FakeGameSocketFactory()
        let clock = FakeLiveGameClock()
        let random = FakeLiveGameRandomSource(values: [0])
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [.hosted, documents.profile], selectedID: documents.profile.id
            ),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.compatible(
                capabilities: [LocaleCatalogLimits.capabilityIdentifier],
                localeCatalog: documents.advertisement
            ))),
            authenticationSession: ScriptedAuthenticating(
                authenticateResult: .success(AuthToken(token: "replacement-token")),
                currentUserResult: .success(.sample)
            ),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: service,
            liveGameSocketFactory: socketFactory,
            liveGameClock: clock,
            liveGameRandomSource: random,
            localeCatalogLoader: loader,
            preferredLanguagesProvider: MulliganPreferredLanguages()
        )
        return (
            model,
            Fakes(
                tokenStore: tokenStore,
                service: service,
                socketFactory: socketFactory,
                clock: clock,
                random: random
            )
        )
    }

    private func startMulliganSession(
        documents: SyntheticLocaleCatalogDocuments,
        loader: LocaleCatalogLoader,
        configureConnection: (FakeGameSocketConnection) async -> Void = { _ in }
    ) async throws -> MulliganSession {
        let (model, fakes) = makeMulliganModel(documents: documents, loader: loader)
        await model.flowTask?.value
        await model.localeCatalogTask?.value
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await configureConnection(connection)
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )
        let questionVersion = envelope.game.scenarioSteps + 1
        let update = try mulliganSnapshotUpdate(
            from: envelope,
            scenarioSteps: questionVersion,
            handCardIDs: Array(Self.mulliganCardCodes.keys).sorted(),
            globalCardIDs: Array(Self.mulliganCardCodes.keys).sorted()
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(update))))
        await connection.waitUntilAwaitingNextEvent()
        return MulliganSession(
            model: model,
            connection: connection,
            gameID: gameID,
            envelope: envelope,
            questionVersion: questionVersion
        )
    }

    private func mulliganSnapshotUpdate(
        from envelope: GetGameEnvelope,
        scenarioSteps: Int,
        handCardIDs: [String],
        globalCardIDs: [String]
    ) throws -> BoardSnapshotUpdate {
        var value = try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(envelope.game)
        )
        guard case var .object(object) = value,
              case var .object(investigators)? = object["investigators"],
              let investigatorKey = investigators.keys.first,
              case var .object(investigator)? = investigators[investigatorKey],
              case var .object(questions)? = object["question"],
              let ownerID = envelope.playerID?.codingKey.stringValue
        else { throw TestFailure() }

        let mulliganQuestion = try loadContractFixtureValue("question-mulligan")
        questions[ownerID] = mulliganQuestion
        object["question"] = .object(questions)
        object["scenarioSteps"] = .number(.integer(Int64(scenarioSteps)))

        let hand = try handCardIDs.map(mulliganPlayerCard)
        investigator["hand"] = .array(hand)
        investigator["handSize"] = .number(.integer(Int64(hand.count)))
        investigators[investigatorKey] = .object(investigator)
        object["investigators"] = .object(investigators)

        let globalCards = try Dictionary(uniqueKeysWithValues: globalCardIDs.map {
            try ($0, mulliganPlayerCard($0))
        })
        object["cards"] = .object(globalCards)
        value = .object(object)
        let snapshot = try ContractJSON.decode(
            PublicGameSnapshot.self,
            from: ContractJSON.encode(value)
        )
        return .snapshot(snapshot)
    }

    private func mulliganPlayerCard(_ id: String) throws -> JSONValue {
        let code = try #require(Self.mulliganCardCodes[id])
        return .object([
            "tag": .string("PlayerCard"),
            "contents": .object([
                "id": .string(id),
                "owner": .string("c01001"),
                "cardCode": .string(code),
                "originalCardCode": .string(code),
                "customizations": .array([]),
                "tabooList": .null,
                "mutated": .null,
                "chained": .null,
                "meta": .null,
                "facedown": .null,
                "errata": .null,
            ]),
        ])
    }

    @Test("A verified catalog resolves done and sends the exact source index zero")
    func verifiedMulliganDoneSends() async throws {
        let documents = try mulliganCatalogDocuments()
        let session = try await startMulliganSession(
            documents: documents,
            loader: documents.loader(),
            configureConnection: { await $0.enqueueSendResult(.success(())) }
        )
        let presentation = try #require(
            session.model.basicChoicePresentation(for: session.gameID)
        )
        let projection = try #require(
            session.model.liveGameState(for: session.gameID).lastKnownProjection
        )
        #expect(presentation.choiceLabelResolutions[0] == .resolved("Done replacing cards"))
        #expect(presentation.choices.map {
            presentation.isChoiceActionable($0, in: projection)
        } == [true, true, true, true])
        #expect(await session.model.submitBasicChoice(
            presentation.identity,
            choiceIndex: 0
        ) == .sentAwaitingSnapshot)
        #expect(await session.connection.sentData == [
            expectedMulliganAnswer(choice: 0, questionVersion: session.questionVersion),
        ])
    }

    @Test("A card choice preserves its source index and duplicate submission sends once")
    func mulliganCardChoiceSendsOnce() async throws {
        let documents = try mulliganCatalogDocuments()
        let session = try await startMulliganSession(
            documents: documents,
            loader: documents.loader(),
            configureConnection: { await $0.setSendGated(true) }
        )
        let presentation = try #require(
            session.model.basicChoicePresentation(for: session.gameID)
        )

        let first = Task {
            await session.model.submitBasicChoice(presentation.identity, choiceIndex: 2)
        }
        await session.connection.waitUntilSendPending(1)
        #expect(await session.model.submitBasicChoice(
            presentation.identity,
            choiceIndex: 2
        ) == .alreadyPending)
        await session.connection.resumeOldestSend(with: .success(()))
        #expect(await first.value == .sentAwaitingSnapshot)
        #expect(await session.connection.sentData == [
            expectedMulliganAnswer(choice: 2, questionVersion: session.questionVersion),
        ])
    }

    @Test("A transient catalog failure leaves cards actionable and retry resolves done")
    func mulliganCatalogRetryDoesNotBlockCards() async throws {
        let documents = try mulliganCatalogDocuments()
        let transport = FixtureLocaleCatalogTransport(responses: [:])
        let session = try await startMulliganSession(
            documents: documents,
            loader: LocaleCatalogLoader(transport: transport)
        )
        let unavailable = try #require(
            session.model.basicChoicePresentation(for: session.gameID)
        )
        let projection = try #require(
            session.model.liveGameState(for: session.gameID).lastKnownProjection
        )
        #expect(unavailable.choiceLabelResolutions[0]
            == .unavailable(.catalog(.transportFailure)))
        #expect(!unavailable.isChoiceActionable(unavailable.choices[0], in: projection))
        #expect(unavailable.isChoiceActionable(unavailable.choices[1], in: projection))
        let retry = try #require(unavailable.catalogRetry)

        await transport.replaceResponse(
            documents.response(data: documents.manifestBytes, url: documents.manifestURL),
            for: documents.manifestURL
        )
        await transport.replaceResponse(
            documents.response(data: documents.chunkBytes, url: documents.chunkURL),
            for: documents.chunkURL
        )
        session.model.retryLocaleCatalog(for: session.gameID, retry: retry)
        await session.model.localeCatalogTask?.value

        let resolved = try #require(
            session.model.basicChoicePresentation(for: session.gameID)
        )
        #expect(resolved.choiceLabelResolutions[0] == .resolved("Done replacing cards"))
        #expect(resolved.catalogRetry == nil)
        #expect(resolved.isChoiceActionable(resolved.choices[0], in: projection))
    }

    @Test("A retryable card clears when it leaves the hand; a sibling can send")
    func retryableMulliganCardClearsWhenTargetLeavesHand() async throws {
        let documents = try mulliganCatalogDocuments()
        let session = try await startMulliganSession(
            documents: documents,
            loader: documents.loader(),
            configureConnection: {
                await $0.enqueueSendResult(.failure(GameSocketTransportError()))
            }
        )
        let initial = try #require(
            session.model.basicChoicePresentation(for: session.gameID)
        )
        #expect(await session.model.submitBasicChoice(
            initial.identity,
            choiceIndex: 2
        ) == .retryableFailure)
        #expect(session.model.basicChoicePresentation(for: session.gameID)?.actionPhase
            == .retryable(.transportFailure))

        let removedCardID = "00000000-0000-0000-0000-0000000003c1"
        let allCardIDs = Array(Self.mulliganCardCodes.keys).sorted()
        let update = try mulliganSnapshotUpdate(
            from: session.envelope,
            scenarioSteps: session.questionVersion,
            handCardIDs: allCardIDs.filter { $0 != removedCardID },
            globalCardIDs: allCardIDs
        )
        try await session.connection.enqueue(.event(.message(ContractJSON.encode(update))))
        await session.connection.waitUntilAwaitingNextEvent()

        let current = try #require(
            session.model.basicChoicePresentation(for: session.gameID)
        )
        let projection = try #require(
            session.model.liveGameState(for: session.gameID).lastKnownProjection
        )
        #expect(current.actionPhase == nil)
        #expect(session.model.basicChoiceActions[session.gameID] == nil)
        #expect(!current.isChoiceActionable(current.choices[2], in: projection))
        #expect(current.isChoiceActionable(current.choices[1], in: projection))

        await session.connection.enqueueSendResult(.success(()))
        #expect(await session.model.submitBasicChoice(
            current.identity,
            choiceIndex: 1
        ) == .sentAwaitingSnapshot)
        #expect(await session.connection.sentData == [
            expectedMulliganAnswer(choice: 2, questionVersion: session.questionVersion),
            expectedMulliganAnswer(choice: 1, questionVersion: session.questionVersion),
        ])
    }

    private func expectedMulliganAnswer(choice: Int, questionVersion: Int) -> Data {
        Data(
            """
            {"contents":{"choice":\(choice),\
            "playerId":"00000000-0000-0000-0000-000000000001",\
            "questionVersion":\(questionVersion)},"tag":"Answer"}
            """.utf8
        )
    }
}
