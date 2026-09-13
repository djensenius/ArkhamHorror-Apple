@testable import ArkhamHorrorShared
import Foundation
import Testing

private struct RoundTransitionPreferredLanguages: PreferredLanguagesProviding {
    let preferredLanguages = ["en"]
}

private struct RoundTransitionSubmissionCase: Sendable {
    let fixture: RoundTransitionFixtures.Fixture
    let questionVersion: Int
    let choiceIndex: Int

    static let everyChoice = [
        RoundTransitionSubmissionCase(
            fixture: .forcedAbility, questionVersion: 24, choiceIndex: 0
        ),
        RoundTransitionSubmissionCase(
            fixture: .agendaAdvance, questionVersion: 25, choiceIndex: 0
        ),
        RoundTransitionSubmissionCase(
            fixture: .agendaConsequence, questionVersion: 26, choiceIndex: 0
        ),
        RoundTransitionSubmissionCase(
            fixture: .agendaConsequence, questionVersion: 26, choiceIndex: 1
        ),
        RoundTransitionSubmissionCase(
            fixture: .agendaHorrorAssignment, questionVersion: 27, choiceIndex: 0
        ),
    ]

    static let staleCoverage = [
        everyChoice[0],
        everyChoice[1],
        everyChoice[3],
        everyChoice[4],
    ]
}

extension AppModelLiveGameTests {
    private func roundTransitionCatalogDocuments() throws -> SyntheticLocaleCatalogDocuments {
        try SyntheticLocaleCatalogDocuments.make(
            pack: "nightOfTheZealot",
            entryKeys: [
                "nightOfTheZealot.theGathering.label.whatsGoingOn.horror",
                "nightOfTheZealot.theGathering.label.whatsGoingOn.discard",
            ],
            chunkEntries: """
            {
              "nightOfTheZealot.theGathering.label.whatsGoingOn.horror":{
                "form":"message","nodes":[{"type":"text",\
                "value":"The lead investigator takes 2 horror"}],"variables":[]
              },
              "nightOfTheZealot.theGathering.label.whatsGoingOn.discard":{
                "form":"message","nodes":[{"type":"text",\
                "value":"Each investigator discards 1 card at random from their hand"}],\
                "variables":[]
              }
            }
            """
        )
    }

    private func makeRoundTransitionModel(
        documents: SyntheticLocaleCatalogDocuments,
        loader: LocaleCatalogLoader? = nil
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
            localeCatalogLoader: loader ?? documents.loader(),
            preferredLanguagesProvider: RoundTransitionPreferredLanguages()
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

    private func roundTransitionEnvelope(
        _ base: GetGameEnvelope,
        fixture: RoundTransitionFixtures.Fixture,
        questionVersion: Int
    ) throws -> GetGameEnvelope {
        let withQuestion = try envelopeReplacingQuestion(
            base,
            scenarioSteps: questionVersion,
            replacingQuestionWith: RoundTransitionFixtures.value(fixture)
        )
        let raw = try ContractJSON.decode(
            JSONValue.self, from: ContractJSON.encode(withQuestion)
        )
        let withTreachery = try EnemyAttackFixtures.applying(
            operation: "add",
            path: [
                "game",
                "treacheries",
                Substring(RoundTransitionFixtures.treacheryID.codingKey.stringValue),
            ],
            replacement: .null,
            to: raw
        )
        return try ContractJSON.decode(
            GetGameEnvelope.self, from: ContractJSON.encode(withTreachery)
        )
    }

    private func roundTransitionAnswer(
        choice: Int, identity: BasicChoicePromptIdentity
    ) -> Data {
        Data(
            """
            {"contents":{"choice":\(choice),\
            "playerId":"\(identity.ownerID.rawValue.uuidString.lowercased())",\
            "questionVersion":\(identity.questionVersion)},"tag":"Answer"}
            """.utf8
        )
    }

    @Test("Every round-transition choice submits its exact source index and version")
    func roundTransitionAnswersAreExact() async throws {
        for testCase in RoundTransitionSubmissionCase.everyChoice {
            let documents = try roundTransitionCatalogDocuments()
            let (model, fakes) = makeRoundTransitionModel(documents: documents)
            await model.flowTask?.value
            await model.localeCatalogTask?.value
            let envelope = try roundTransitionEnvelope(
                loadGetGame(),
                fixture: testCase.fixture,
                questionVersion: testCase.questionVersion
            )
            let connection = FakeGameSocketConnection()
            await connection.enqueueSendResult(.success(()))
            let gameID = await startChoiceSession(
                model: model, fakes: fakes, envelope: envelope, connection: connection
            )
            let presentation = try #require(model.basicChoicePresentation(for: gameID))
            let projection = try #require(
                model.liveGameStates[gameID]?.lastKnownProjection
            )
            #expect(presentation.questionVersion == testCase.questionVersion)
            let choice = try #require(
                presentation.choices.first { $0.index == testCase.choiceIndex }
            )
            #expect(presentation.isChoiceActionable(choice, in: projection))
            #expect(
                await model.submitBasicChoice(
                    presentation.identity, choiceIndex: testCase.choiceIndex
                ) == .sentAwaitingSnapshot
            )
            #expect(await connection.sentData == [
                roundTransitionAnswer(
                    choice: testCase.choiceIndex, identity: presentation.identity
                ),
            ])
        }
    }

    @Test("Every older round-transition prompt is rejected after a newer snapshot")
    func staleRoundTransitionPromptsFailClosed() async throws {
        for testCase in RoundTransitionSubmissionCase.staleCoverage {
            let documents = try roundTransitionCatalogDocuments()
            let (model, fakes) = makeRoundTransitionModel(documents: documents)
            await model.flowTask?.value
            await model.localeCatalogTask?.value
            let question = try RoundTransitionFixtures.value(testCase.fixture)
            let envelope = try roundTransitionEnvelope(
                loadGetGame(),
                fixture: testCase.fixture,
                questionVersion: testCase.questionVersion
            )
            let connection = FakeGameSocketConnection()
            let gameID = await startChoiceSession(
                model: model, fakes: fakes, envelope: envelope, connection: connection
            )
            let stale = try #require(model.basicChoicePresentation(for: gameID)?.identity)
            let update = try snapshotUpdate(
                from: envelope,
                scenarioSteps: testCase.questionVersion + 1,
                replacingQuestionWith: question
            )
            try await connection.enqueue(.event(.message(ContractJSON.encode(update))))
            await connection.waitUntilAwaitingNextEvent()
            let current = try #require(model.basicChoicePresentation(for: gameID))
            #expect(current.identity != stale)
            #expect(
                await model.submitBasicChoice(stale, choiceIndex: testCase.choiceIndex)
                    == .staleQuestion
            )
            #expect(await connection.sentData.isEmpty)
        }
    }

    @Test("A failed localized consequence retries only on refreshed connection authority")
    func agendaConsequenceRetryReconcilesConnectionIdentity() async throws {
        let documents = try roundTransitionCatalogDocuments()
        let (model, fakes) = makeRoundTransitionModel(documents: documents)
        await model.flowTask?.value
        await model.localeCatalogTask?.value
        let envelope = try roundTransitionEnvelope(
            loadGetGame(),
            fixture: .agendaConsequence,
            questionVersion: 26
        )
        let first = FakeGameSocketConnection()
        await first.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: first
        )
        let oldIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(
            await model.submitBasicChoice(oldIdentity, choiceIndex: 1)
                == .retryableFailure
        )

        let replacement = FakeGameSocketConnection()
        await fakes.socketFactory.enqueueConnectResult(.success(replacement))
        await fakes.service.enqueueGetGameResult(.success(envelope))
        await first.enqueue(.failure(GameSocketTransportError()))
        await replacement.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.identity != oldIdentity)
        #expect(current.choiceLabelResolutions
            == RoundTransitionFixtures.resolvedConsequenceLabels)
        #expect(current.actionPhase == .retryable(.transportFailure))

        await replacement.enqueueSendResult(.success(()))
        #expect(await model.retryBasicChoice(current.identity) == .sentAwaitingSnapshot)
        let expected = roundTransitionAnswer(choice: 1, identity: current.identity)
        #expect(await first.sentData == [roundTransitionAnswer(
            choice: 1, identity: oldIdentity
        )])
        #expect(await replacement.sentData == [expected])
    }

    @Test("A transient catalog failure keeps both consequences disabled until retry resolves")
    func agendaConsequenceCatalogRetryRestoresActionability() async throws {
        let documents = try roundTransitionCatalogDocuments()
        let transport = FixtureLocaleCatalogTransport(responses: [:])
        let (model, fakes) = makeRoundTransitionModel(
            documents: documents,
            loader: LocaleCatalogLoader(transport: transport)
        )
        await model.flowTask?.value
        await model.localeCatalogTask?.value
        let envelope = try roundTransitionEnvelope(
            loadGetGame(),
            fixture: .agendaConsequence,
            questionVersion: 26
        )
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: FakeGameSocketConnection()
        )
        let projection = try #require(
            model.liveGameStates[gameID]?.lastKnownProjection
        )
        let unavailable = try #require(model.basicChoicePresentation(for: gameID))
        #expect(unavailable.choiceLabelResolutions.values.allSatisfy {
            $0 == .unavailable(.catalog(.transportFailure))
        })
        #expect(unavailable.choices.allSatisfy {
            !unavailable.isChoiceActionable($0, in: projection)
        })
        let retry = try #require(unavailable.catalogRetry)

        await transport.replaceResponse(
            documents.response(data: documents.manifestBytes, url: documents.manifestURL),
            for: documents.manifestURL
        )
        await transport.replaceResponse(
            documents.response(data: documents.chunkBytes, url: documents.chunkURL),
            for: documents.chunkURL
        )
        model.retryLocaleCatalog(for: gameID, retry: retry)
        await model.localeCatalogTask?.value

        let resolved = try #require(model.basicChoicePresentation(for: gameID))
        #expect(resolved.choiceLabelResolutions
            == RoundTransitionFixtures.resolvedConsequenceLabels)
        #expect(resolved.catalogRetry == nil)
        #expect(resolved.choices.allSatisfy {
            resolved.isChoiceActionable($0, in: projection)
        })
    }
}
