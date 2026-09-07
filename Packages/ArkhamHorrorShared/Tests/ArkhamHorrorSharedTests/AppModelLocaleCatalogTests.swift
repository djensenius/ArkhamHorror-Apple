@testable import ArkhamHorrorShared
import Foundation
import Testing

private struct SyntheticPreferredLanguages: PreferredLanguagesProviding {
    let preferredLanguages: [String]
}

@MainActor
@Suite("AppModel locale catalog lifecycle")
struct AppModelLocaleCatalogTests {
    private func loader(for documents: SyntheticLocaleCatalogDocuments) -> LocaleCatalogLoader {
        LocaleCatalogLoader(transport: FixtureLocaleCatalogTransport(responses: [
            documents.manifestURL: documents.response(
                data: documents.manifestBytes, url: documents.manifestURL
            ),
            documents.chunkURL: documents.response(
                data: documents.chunkBytes, url: documents.chunkURL
            ),
        ]))
    }

    private func model(
        documents: SyntheticLocaleCatalogDocuments,
        loader: LocaleCatalogLoader
    ) -> AppModel {
        AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [.hosted, documents.profile],
                selectedID: documents.profile.id
            ),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.compatible(
                capabilities: [LocaleCatalogLimits.capabilityIdentifier],
                localeCatalog: documents.advertisement
            ))),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            localeCatalogLoader: loader,
            preferredLanguagesProvider: SyntheticPreferredLanguages(preferredLanguages: ["en-US"])
        )
    }

    @Test("Capability probing retains and publishes a verified catalog for the active profile")
    func capabilityAdvertisementPublishesCatalog() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let model = model(documents: documents, loader: loader(for: documents))
        await model.flowTask?.value
        await model.localeCatalogTask?.value

        #expect(
            model.localeCatalog?.identity.catalogRevision == documents.advertisement.catalogRevision
        )
        #expect(model.localeCatalogFailure == nil)
        #expect(!model.isLocaleCatalogLoading)
        #expect(model.localeCatalogResolver?.render(
            key: "story.body", variables: .object([:])
        ) == .success([.text("Synthetic body")]))
    }

    @Test("A stale catalog completion cannot republish after profile invalidation")
    func staleCompletionIsGenerationFenced() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let loaded = try await loader(for: documents).load(
            advertisement: documents.advertisement,
            profile: documents.profile,
            preferredLanguages: ["en"]
        ).get()
        let model = model(documents: documents, loader: loader(for: documents))
        await model.flowTask?.value
        let request = try #require(model.localeCatalogRequest)
        let oldGeneration = model.localeCatalogGeneration

        model.invalidateLocaleCatalog(failure: .notAdvertised)
        model.applyLocaleCatalogResult(
            .success(loaded),
            request: request,
            catalogGeneration: oldGeneration
        )
        #expect(model.localeCatalog == nil)
        #expect(model.localeCatalogFailure == .notAdvertised)
    }

    @Test("A transient catalog failure retries without restarting the selected profile flow")
    func transientCatalogFailureRetriesInPlace() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let model = model(documents: documents, loader: loader(for: documents))
        await model.flowTask?.value
        await model.localeCatalogTask?.value
        let initialGeneration = model.generation

        model.localeCatalog = nil
        model.localeCatalogFailure = .transportFailure
        model.retryLocaleCatalog()
        await model.localeCatalogTask?.value

        #expect(model.generation == initialGeneration)
        #expect(
            model.localeCatalog?.identity.catalogRevision == documents.advertisement.catalogRevision
        )
        #expect(model.localeCatalogFailure == nil)
    }
}
