@testable import ArkhamHorrorShared
import Foundation
import SwiftUI
import Testing

@MainActor
@Suite("AppModel story asset composition")
struct AppModelStoryAssetTests {
    func withModel(
        settingsStatus: Int = 200,
        catalogStatus: Int = 200,
        cacheConstructionFailures: Int = 0,
        documents suppliedDocuments: SyntheticLocaleCatalogDocuments? = nil,
        _ body: (
            AppModel,
            SyntheticLocaleCatalogDocuments,
            FixtureLocaleCatalogTransport,
            FixtureLocaleCatalogTransport,
            ScriptedStoryAssetCacheFactory
        ) async throws -> Void
    ) async throws {
        let documents = try suppliedDocuments ?? StoryCatalogImageTests.documents()
        let settingsURL = documents.profile.endpointURL(path: "/site-settings")
        let transport = FixtureLocaleCatalogTransport(responses: [
            settingsURL: documents.response(
                data: Data(#"{"assetHost":"https://selected-cdn.test/prefix"}"#.utf8),
                status: settingsStatus, url: settingsURL
            ),
        ])
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/StoryAssetTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = ScriptedStoryAssetCacheFactory(
            directory: directory, failures: cacheConstructionFailures
        )
        let catalogTransport = catalogStatus == 200
            ? offlineAfterLoadCatalogTransport(documents)
            : failingCatalogTransport(documents, status: catalogStatus)
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [.hosted, documents.profile], selectedID: documents.profile.id
            ),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.compatible(
                capabilities: [LocaleCatalogLimits.capabilityIdentifier],
                localeCatalog: documents.advertisement
            ))),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            localeCatalogLoader: LocaleCatalogLoader(transport: catalogTransport),
            assetCacheFactory: { factory.make() },
            storyAssetSourceLoader: StoryAssetSourceLoader(transport: transport)
        )
        await model.flowTask?.value
        await model.localeCatalogTask?.value
        try await body(model, documents, transport, catalogTransport, factory)
    }
}

extension AppModelStoryAssetTests {
    func fixtureData(named fileName: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: fileName,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    func installGatheringReadPrompt(
        on model: AppModel,
        profile: ServerProfile,
        participant: LiveGameParticipantIdentity? = nil
    ) throws -> GameID {
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: fixtureData(named: "get-game")
        )
        let rawQuestion = try ContractJSON.decode(
            JSONValue.self,
            from: ReadStoryQuestionTests().fixture("question-read")
        )
        var value = try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(envelope.game)
        )
        guard case var .object(object) = value,
              case var .object(questions)? = object["question"],
              let ownerID = envelope.playerID
        else {
            throw TestFailure()
        }
        object.removeValue(forKey: "questionPresentation")
        questions[ownerID.rawValue.uuidString.lowercased()] = rawQuestion
        object["question"] = .object(questions)
        value = .object(object)
        let snapshot = try ContractJSON.decode(
            PublicGameSnapshot.self,
            from: ContractJSON.encode(value)
        )
        let gameID = snapshot.id
        model.sessionState = .signedIn(
            profile: profile,
            compatibility: .modern(capabilities: [LocaleCatalogLimits.capabilityIdentifier]),
            user: .sample
        )
        model.liveGameStates[gameID] = .live(
            BoardProjectionBuilder.makeProjection(from: snapshot)
        )
        model.liveGameParticipantIdentities[gameID] = participant ?? .participant(ownerID)
        let attemptID = UUID()
        model.liveGameSessions[gameID] = LiveGameSessionHandle(
            attemptID: attemptID,
            task: Task {}
        )
        model.liveGameConnections[gameID] = LiveGameConnectionHandle(
            attemptID: attemptID,
            connectionID: UUID(),
            connection: FakeGameSocketConnection()
        )
        return gameID
    }

    func firstGatheringListEntry(
        in presentation: BasicChoicePromptPresentation
    ) -> ResolvedStoryEntry? {
        guard case let .list(items)? = presentation.storyResolution?.story?.body.first else {
            return nil
        }
        return items.first?.entry
    }

    func expectedGatheringImageFallbackNodes() -> [StoryNode] {
        [
            .text("Collect these encounter sets: "),
            .text(" The Gathering encounter set symbol "),
            .text(" Rats encounter set symbol "),
            .text(" Ghouls encounter set symbol "),
            .text(" Striking Fear encounter set symbol "),
            .text(" Ancient Evils encounter set symbol "),
            .text(" Chilling Cold encounter set symbol "),
            .text(" Then continue."),
        ]
    }

    func expectedGatheringImageFallbackText() -> String {
        [
            "Collect these encounter sets:",
            "The Gathering encounter set symbol",
            "Rats encounter set symbol",
            "Ghouls encounter set symbol",
            "Striking Fear encounter set symbol",
            "Ancient Evils encounter set symbol",
            "Chilling Cold encounter set symbol",
            "Then continue.",
        ].joined(separator: "  ")
    }

    @Test("Source and catalog publish atomically, with an injectable shared SwiftUI cache")
    func composesAndFencesSource() async throws {
        try await withModel { model, _, _, _, _ in
            let source = try AssetSourceNamespace(rawAssetBase: "https://selected-cdn.test/prefix")
            #expect(model.storyAssetSource == source)
            let resolver = try #require(model.localeCatalogResolver)
            #expect(try StoryCatalogImageTests.prompt(resolver: resolver).canSubmit)
            let nodes = try resolver.render(
                key: StoryCatalogImageTests.gatheringKey, variables: .object([:])
            ).get()
            for case let .image(reference) in nodes {
                #expect(reference.assetKey?.source == source)
            }
            var environment = EnvironmentValues()
            #expect(environment.storyAssetCache == nil)
            environment.storyAssetCache = model.assetCacheService
            #expect(environment.storyAssetCache === model.assetCacheService)

            let request = try #require(model.localeCatalogRequest)
            let snapshot = try #require(model.localeCatalog)
            let generation = model.localeCatalogGeneration
            model.invalidateLocaleCatalog()
            model.applyLocaleCatalogResult(
                .success(snapshot), request: request, catalogGeneration: generation,
                assetSource: source
            )
            #expect(model.storyAssetSource == nil)
            #expect(model.localeCatalogResolver == nil)
        }
    }

    @Test("Source-only retry preserves the verified catalog while its transport is offline")
    func failedSourceCanRetryWithoutChangingSession() async throws {
        try await withModel(settingsStatus: 503) { model, documents, transport, catalog, factory in
            let snapshot = try #require(model.localeCatalog)
            let request = model.localeCatalogRequest
            let gameID = try installGatheringReadPrompt(on: model, profile: documents.profile)
            var prompt = try #require(model.basicChoicePresentation(for: gameID))
            #expect(prompt.canSubmit)
            let gatheringFallback = try #require(firstGatheringListEntry(in: prompt))
            #expect(gatheringFallback == .nodes(expectedGatheringImageFallbackNodes()))
            guard case let .nodes(fallbackNodes) = gatheringFallback else { throw TestFailure() }
            let fallbackText = expectedGatheringImageFallbackText()
            #expect(fallbackNodes.map(\.plainText).joined() == fallbackText)
            #expect(StoryNodePresentation.accessibilityLabel(for: fallbackNodes) == fallbackText)
            #expect(!fallbackText.contains("symbolRats"))
            let retry = try #require(prompt.catalogRetry)
            #expect(retry.profileID == documents.profile.id)
            #expect(retry.catalogGeneration == model.localeCatalogGeneration)
            #expect(retry.scope == .images)
            #expect(retry.title == "Retry story images")
            try expectTextActionable(model)
            #expect(model.storyAssetSource == nil)
            #expect(model.storyAssetSourceFailure == .unexpectedStatus(503))
            let generation = model.generation
            let url = documents.profile.endpointURL(path: "/site-settings")
            await transport.replaceResponse(documents.response(
                data: Data(#"{"assetHost":"https://replacement-cdn.test"}"#.utf8), url: url
            ), for: url)
            model.retryLocaleCatalog()
            #expect(model.localeCatalog == snapshot)
            #expect(model.localeCatalogRequest == request)
            #expect(!model.isLocaleCatalogLoading)
            let loadingResolver = try #require(model.localeCatalogResolver)
            #expect(loadingResolver.render(
                key: StoryCatalogImageTests.gatheringKey, variables: .object([:])
            ) == .failure(.imageSourceLoading))
            try expectTextActionable(model)
            prompt = try #require(model.basicChoicePresentation(for: gameID))
            #expect(prompt.canSubmit)
            model.retryLocaleCatalog()
            await model.localeCatalogTask?.value
            #expect(model.generation == generation)
            #expect(model.localeCatalog == snapshot)
            #expect(model.localeCatalogRequest == request)
            #expect(await catalog.requests.count == 2)
            #expect(await transport.requests.count == 2)
            #expect(factory.attempts == 1)
            #expect(model.storyAssetSourceFailure == nil)
            prompt = try #require(model.basicChoicePresentation(for: gameID))
            #expect(prompt.catalogRetry == nil)
            #expect(try model
                .storyAssetSource ==
                AssetSourceNamespace(rawAssetBase: "https://replacement-cdn.test"))
            #expect(try StoryCatalogImageTests
                .prompt(resolver: #require(model.localeCatalogResolver)).canSubmit)
        }
    }

    @Test("Mixed image fallback keeps AppModel retry for source failures in either order")
    func mixedImageFallbackOrderPreservesSourceRetry() async throws {
        let unsupportedFirst = try StoryCatalogImageTests.documents(
            firstPath: "encounter-sets//the-gathering.png"
        )
        let unsupportedLast = try StoryCatalogImageTests.documents(
            lastPath: "encounter-sets//chilling-cold.png"
        )
        for documents in [unsupportedFirst, unsupportedLast] {
            try await withModel(settingsStatus: 503, documents: documents) {
                model, documents, _, _, _ in
                let gameID = try installGatheringReadPrompt(on: model, profile: documents.profile)
                let prompt = try #require(model.basicChoicePresentation(for: gameID))
                #expect(prompt.canSubmit)
                #expect(
                    prompt.storyResolution?.unavailableReason == .catalog(.unexpectedStatus(503))
                )
                let retry = try #require(prompt.catalogRetry)
                #expect(retry.profileID == documents.profile.id)
                #expect(retry.catalogGeneration == model.localeCatalogGeneration)
                #expect(retry.scope == .images)
                #expect(retry.title == "Retry story images")
            }
        }
    }

    @Test("Catalog fetch failure keeps Read fallback answerable and offers AppModel retry")
    func catalogFetchFailurePresentationHasRetry() async throws {
        try await withModel(catalogStatus: 503) { model, documents, _, _, _ in
            #expect(model.localeCatalog == nil)
            #expect(model.localeCatalogFailure == .unexpectedStatus(503))
            let gameID = try installGatheringReadPrompt(on: model, profile: documents.profile)
            let prompt = try #require(model.basicChoicePresentation(for: gameID))
            #expect(prompt.canSubmit)
            #expect(firstGatheringListEntry(in: prompt) == .text(
                StoryCatalogImageTests.gatheringKey
            ))
            let retry = try #require(prompt.catalogRetry)
            #expect(retry.profileID == documents.profile.id)
            #expect(retry.catalogGeneration == model.localeCatalogGeneration)
            #expect(retry.scope == .catalog)
            #expect(retry.title == "Retry prompt text")
        }
    }

    @Test("Degraded image story does not override read-only prompt status")
    func degradedImageKeepsReadOnlyStatus() async throws {
        try await withModel(settingsStatus: 503) { model, documents, _, _, _ in
            let gameID = try installGatheringReadPrompt(
                on: model,
                profile: documents.profile,
                participant: .spectator
            )
            let spectatorPrompt = try #require(model.basicChoicePresentation(for: gameID))
            #expect(
                spectatorPrompt.storyResolution?.unavailableReason
                    == .catalog(.unexpectedStatus(503))
            )
            #expect(spectatorPrompt.catalogRetry != nil)
            #expect(
                spectatorPrompt.statusMessage
                    == "Spectators can view this prompt but cannot answer it."
            )

            let waitingPrompt = BasicChoicePromptPresentation(
                identity: spectatorPrompt.identity,
                question: spectatorPrompt.question,
                semanticPresentation: spectatorPrompt.semanticPresentation,
                semanticLocaleIdentifier: spectatorPrompt.semanticLocaleIdentifier,
                cardCatalog: spectatorPrompt.cardCatalog,
                storyResolution: spectatorPrompt.storyResolution,
                choiceLabelResolutions: spectatorPrompt.choiceLabelResolutions,
                choiceFlavorResolutions: spectatorPrompt.choiceFlavorResolutions,
                promptLabelResolutions: spectatorPrompt.promptLabelResolutions,
                readOnlyReason: .anotherPlayer,
                actionPhase: nil,
                actionChoiceIndex: nil,
                serverFeedback: nil,
                catalogRetry: spectatorPrompt.catalogRetry
            )
            #expect(waitingPrompt.statusMessage == "Waiting for another player to answer.")
            #expect(waitingPrompt.catalogRetry != nil)
        }
    }
}
