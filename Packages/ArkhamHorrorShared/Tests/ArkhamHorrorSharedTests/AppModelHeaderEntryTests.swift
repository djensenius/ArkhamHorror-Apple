@testable import ArkhamHorrorShared
import Foundation
import Testing

private struct HeaderEntryPreferredLanguages: PreferredLanguagesProviding {
    let preferredLanguages = ["en"]
}

private struct HeaderEntrySession {
    let model: AppModel
    let connection: FakeGameSocketConnection
    let gameID: GameID
    let envelope: GetGameEnvelope
    let questionVersion: Int
}

extension AppModelLiveGameTests {
    @Test("A verified HeaderEntry story is controller-actionable and sends Continue index zero")
    func verifiedHeaderEntryStorySendsContinue() async throws {
        let session = try await startVerifiedHeaderEntrySession()
        let presentation = try #require(
            session.model.basicChoicePresentation(for: session.gameID)
        )
        #expect(presentation.storyResolution == .resolved(ResolvedStory(
            title: "notz.intro.title.en",
            body: [
                .heading(level: .level1, nodes: [.text("notz.intro.title.en")]),
                .nodes([.text("notz.intro.body.en")]),
            ]
        )))
        #expect(presentation.canSubmit)

        let projection = BoardProjectionBuilder.makeProjection(from: session.envelope.game)
        #expect(BoardDisplayFormatting.choiceAccessibilityHint(
            for: presentation.choices[0],
            in: projection,
            storyResolution: presentation.storyResolution,
            canSubmit: presentation.canSubmit,
            statusMessage: presentation.statusMessage
        ) == "Activates choice 1.")

        assertControllerActivation(presentation: presentation, projection: projection)
        #expect(
            await session.model.submitBasicChoice(presentation.identity, choiceIndex: 0)
                == .sentAwaitingSnapshot
        )
        #expect(await session.connection.sentData == [
            expectedContinueAnswer(questionVersion: session.questionVersion),
        ])
    }

    private func startVerifiedHeaderEntrySession() async throws -> HeaderEntrySession {
        let documents = try headerEntryCatalogDocuments()
        let (model, fakes) = makeCatalogSignedInModel(documents: documents)
        await model.flowTask?.value
        await model.localeCatalogTask?.value
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let readQuestion = try loadContractFixtureValue("question-read-scenario-intro")
        let questionVersion = envelope.game.scenarioSteps + 1
        let update = try snapshotUpdate(
            from: envelope,
            scenarioSteps: questionVersion,
            replacingQuestionWith: readQuestion
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(update))))
        await connection.waitUntilAwaitingNextEvent()
        return HeaderEntrySession(
            model: model,
            connection: connection,
            gameID: gameID,
            envelope: envelope,
            questionVersion: questionVersion
        )
    }

    private func headerEntryCatalogDocuments() throws -> SyntheticLocaleCatalogDocuments {
        try SyntheticLocaleCatalogDocuments.make(
            pack: "nightOfTheZealot",
            entryKeys: [
                "nightOfTheZealot.theGathering.intro.body",
                "nightOfTheZealot.theGathering.intro.title",
            ],
            chunkEntries: """
            {"nightOfTheZealot.theGathering.intro.body":{"form":"message","nodes":[\
            {"type":"text","value":"notz.intro.body.en"}],"variables":[]},\
            "nightOfTheZealot.theGathering.intro.title":{"form":"message","nodes":[\
            {"type":"text","value":"notz.intro.title.en"}],"variables":[]}}
            """
        )
    }

    private func makeCatalogSignedInModel(
        documents: SyntheticLocaleCatalogDocuments
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
            localeCatalogLoader: documents.loader(),
            preferredLanguagesProvider: HeaderEntryPreferredLanguages()
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

    private func assertControllerActivation(
        presentation: BasicChoicePromptPresentation,
        projection: BoardProjection
    ) {
        var choices: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: presentation,
            onChoice: { choices.append($0) }
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.activatePromptChoice(0))
        #expect(choices == [0])
    }

    private func expectedContinueAnswer(questionVersion: Int) -> Data {
        Data(
            """
            {"contents":{"choice":0,\
            "playerId":"00000000-0000-0000-0000-000000000001",\
            "questionVersion":\(questionVersion)},"tag":"Answer"}
            """.utf8
        )
    }
}
