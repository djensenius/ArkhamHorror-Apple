@testable import ArkhamHorrorShared
import Foundation
import SwiftUI
import Testing

@MainActor
@Suite("AppModel story asset composition")
struct AppModelStoryAssetTests {
    func withModel(
        settingsStatus: Int = 200,
        cacheConstructionFailures: Int = 0,
        _ body: (
            AppModel,
            SyntheticLocaleCatalogDocuments,
            FixtureLocaleCatalogTransport,
            FixtureLocaleCatalogTransport,
            ScriptedStoryAssetCacheFactory
        ) async throws -> Void
    ) async throws {
        let documents = try StoryCatalogImageTests.documents()
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
        let catalogTransport = offlineAfterLoadCatalogTransport(documents)
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
            let resolver = try #require(model.localeCatalogResolver)
            let snapshot = try #require(model.localeCatalog)
            let request = model.localeCatalogRequest
            let prompt = try StoryCatalogImageTests.prompt(resolver: resolver)
            #expect(!prompt.canSubmit)
            let retry = model.catalogRetryPresentation(
                localizationReasons: [.catalog(.unexpectedStatus(503))],
                promptKey: prompt.identity.promptKey
            )
            #expect(retry?.profileID == documents.profile.id)
            #expect(retry?.catalogGeneration == model.localeCatalogGeneration)
            #expect(retry?.scope == .images)
            #expect(retry?.title == "Retry story images")
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
            model.retryLocaleCatalog()
            await model.localeCatalogTask?.value
            #expect(model.generation == generation)
            #expect(model.localeCatalog == snapshot)
            #expect(model.localeCatalogRequest == request)
            #expect(await catalog.requests.count == 2)
            #expect(await transport.requests.count == 2)
            #expect(factory.attempts == 1)
            #expect(model.storyAssetSourceFailure == nil)
            #expect(model.catalogRetryPresentation(
                localizationReasons: [.catalog(.unexpectedStatus(503))],
                promptKey: prompt.identity.promptKey
            ) == nil)
            #expect(try model
                .storyAssetSource ==
                AssetSourceNamespace(rawAssetBase: "https://replacement-cdn.test"))
            #expect(try StoryCatalogImageTests
                .prompt(resolver: #require(model.localeCatalogResolver)).canSubmit)
        }
    }
}
