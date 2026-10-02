@testable import ArkhamHorrorShared
import Foundation
import SwiftUI
import Testing

@MainActor
final class ScriptedStoryAssetCacheFactory {
    let directory: URL
    let failures: Int
    private(set) var attempts = 0

    init(directory: URL, failures: Int) {
        self.directory = directory
        self.failures = failures
    }

    func make() -> AssetCacheService? {
        attempts += 1
        guard attempts > failures else { return nil }
        do {
            return try AssetCacheService(
                memoryCache: AssetMemoryCache(limits: .production),
                diskCache: AssetDiskCache(directory: directory, limits: .production),
                transport: FakeAssetTransport()
            )
        } catch {
            Issue.record("Unexpected test cache initialization failure: \(error)")
            return nil
        }
    }
}

func offlineAfterLoadCatalogTransport(
    _ documents: SyntheticLocaleCatalogDocuments
) -> FixtureLocaleCatalogTransport {
    let documentsByURL = [
        documents.manifestURL: documents.manifestBytes,
        documents.chunkURL: documents.chunkBytes,
    ]
    return FixtureLocaleCatalogTransport(
        responses: Dictionary(uniqueKeysWithValues: documentsByURL.map { url, _ in
            (url, documents.response(data: Data(), status: 503, url: url))
        }),
        sequences: Dictionary(uniqueKeysWithValues: documentsByURL.map { url, data in
            (url, [documents.response(data: data, url: url)])
        })
    )
}

func failingCatalogTransport(
    _ documents: SyntheticLocaleCatalogDocuments,
    status: Int
) -> FixtureLocaleCatalogTransport {
    FixtureLocaleCatalogTransport(responses: [
        documents.manifestURL: documents.response(
            data: Data(),
            status: status,
            url: documents.manifestURL
        ),
        documents.chunkURL: documents.response(
            data: Data(),
            status: status,
            url: documents.chunkURL
        ),
    ])
}

extension AppModelStoryAssetTests {
    func expectTextActionable(_ model: AppModel) throws {
        #expect(!model.isLocaleCatalogLoading)
        let resolver = try #require(model.localeCatalogResolver)
        #expect(resolver.render(
            key: "setup", variables: .object([:])
        ) == .success([.text("Setup")]))
        let prompt = try StoryCatalogImageTests.prompt(resolver: resolver, includingImages: false)
        #expect(prompt.canSubmit)
        let controller = BoardCommandController(
            projection: BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot()),
            prompt: prompt
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.activatePromptChoice(0))
    }

    @Test(
        "Local cache failures have accurate status and controller-retry recovery without relaunch"
    )
    func localCacheRecovery() async throws {
        try await withModel(cacheConstructionFailures: 2) { model, documents, source, catalog, factory in
            let snapshot = model.localeCatalog
            let gameID = try installGatheringReadPrompt(on: model, profile: documents.profile)
            var prompt = try #require(model.basicChoicePresentation(for: gameID))
            let reason = StoryUnavailableReason.imagePipelineUnavailable
            #expect(prompt.storyResolution?.unavailableReason == reason)
            #expect(prompt.storyResolution?.story?.body.isEmpty == false)
            #expect(prompt.canSubmit)
            #expect(model.assetCacheService == nil)
            try expectTextActionable(model)
            #expect(await source.requests.isEmpty)
            #expect(factory.attempts == 1)
            let retry = try #require(prompt.catalogRetry)
            #expect(retry.scope == .localImagePipeline)
            #expect(retry.title == "Retry image support")
            #expect(retry.accessibilityHint.contains("this app's local image cache"))
            let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
            let controller = BoardCommandController(
                projection: projection,
                prompt: prompt,
                onCatalogRetry: { model.retryLocaleCatalog(for: gameID, retry: $0) }
            )
            #expect(controller.activatePromptChoice(0))
            #expect(controller.handle(.command(.jumpToActivePrompt)))
            #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
            #expect(controller.activatePromptCatalogRetry())
            #expect(factory.attempts == 2)
            #expect(model.localeCatalog == snapshot)
            #expect(model.localeCatalogRetryReason == reason)
            prompt = try #require(model.basicChoicePresentation(for: gameID))
            controller.applyPrompt(prompt)
            #expect(controller.activatePromptCatalogRetry())
            #expect(model.assetCacheService != nil)
            #expect(model.localeCatalog == snapshot)
            await model.localeCatalogTask?.value
            #expect(factory.attempts == 3)
            #expect(await source.requests.count == 1)
            #expect(await catalog.requests.count == 2)
            let recovered = try #require(model.basicChoicePresentation(for: gameID))
            #expect(recovered.canSubmit)
            #expect(model.localeCatalogRetryReason == nil)
            controller.applyPrompt(recovered)
            #expect(controller.handle(.command(.jumpToActivePrompt)))
            #expect(controller.activatePromptChoice(0))
        }
    }

    @Test("Once recovered, windows and source retries reuse the single successful cache")
    func recoveredCacheIsShared() async throws {
        try await withModel(
            settingsStatus: 503, cacheConstructionFailures: 1
        ) { model, _, _, _, factory in
            model.retryLocaleCatalog()
            await model.localeCatalogTask?.value
            let cache = try #require(model.assetCacheService)
            #expect(model.prepareStoryAssetCache())
            #expect(model.prepareStoryAssetCache())
            let firstWindow = RootView(model: model)
            let secondWindow = RootView(model: model)
            #expect(firstWindow.modelIdentityForArchitectureTest ==
                secondWindow.modelIdentityForArchitectureTest)
            model.retryLocaleCatalog()
            await model.localeCatalogTask?.value
            #expect(model.assetCacheService === cache)
            #expect(factory.attempts == 2)
        }
    }

    @Test("Late source-only completion cannot republish after catalog invalidation")
    func sourceRetryFence() async throws {
        try await withModel(settingsStatus: 503) { model, _, _, _, _ in
            let request = try #require(model.localeCatalogRequest)
            model.retryLocaleCatalog()
            let generation = model.localeCatalogGeneration
            let sourceTask = model.localeCatalogTask
            let cache = model.assetCacheService
            model.invalidateLocaleCatalog()
            await sourceTask?.value
            model.applyStoryAssetSourceResult(
                .success(.hosted), request: request, catalogGeneration: generation
            )
            #expect(model.localeCatalog == nil)
            #expect(model.storyAssetSource == nil)
            #expect(model.storyAssetSourceFailure == nil)
            #expect(model.assetCacheService === cache)
        }
    }
}
