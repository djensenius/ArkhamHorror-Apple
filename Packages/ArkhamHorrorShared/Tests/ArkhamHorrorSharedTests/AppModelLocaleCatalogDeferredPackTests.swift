@testable import ArkhamHorrorShared
import Foundation
import Testing

private struct FixedPreferredLanguages: PreferredLanguagesProviding {
    let preferredLanguages: [String]
}

/// Holds requests for `gated` URLs until ``release()``; everything else passes straight
/// through to the fixture transport.
private actor GatedLocaleCatalogTransport: LocaleCatalogTransporting {
    let inner: FixtureLocaleCatalogTransport
    let gated: Set<URL>
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var heldRequests = 0

    init(inner: FixtureLocaleCatalogTransport, gated: Set<URL>) {
        self.inner = inner
        self.gated = gated
    }

    func fetch(_ url: URL, maxBytes: Int) async throws -> LocaleCatalogResponse {
        if gated.contains(url), !isOpen {
            heldRequests += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        return try await inner.fetch(url, maxBytes: maxBytes)
    }

    func release() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters = []
    }
}

/// TASK-1.40: the app loads the `cardNames` packs on the first label that needs one, keeps
/// the server-sent name until then (and after a failure), and never adopts a stale load.
@MainActor
@Suite("AppModel deferred locale catalog packs")
struct AppModelLocaleCatalogDeferredPackTests {
    private static let swarm: JSONValue = .object([
        "name": .string("Swarm of Rats"), "__name": .string("01159"),
    ])

    private func model(
        catalog: VendoredLocaleCatalog,
        loader: LocaleCatalogLoader,
        languages: [String] = ["de"]
    ) -> AppModel {
        AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [.hosted, catalog.profile],
                selectedID: catalog.profile.id
            ),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.compatible(
                capabilities: [LocaleCatalogLimits.capabilityIdentifier],
                localeCatalog: catalog.advertisement
            ))),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            localeCatalogLoader: loader,
            preferredLanguagesProvider: FixedPreferredLanguages(preferredLanguages: languages),
            webIconFontLoader: NoopWebIconFontLoader()
        )
    }

    private func loadedModel(
        catalog: VendoredLocaleCatalog, loader: LocaleCatalogLoader
    ) async -> AppModel {
        let model = model(catalog: catalog, loader: loader)
        await model.flowTask?.value
        await model.localeCatalogTask?.value
        return model
    }

    /// The `name` a label would show right now.
    private func shownName(_ model: AppModel) -> JSONValue? {
        guard case let .object(values) = StoryNarrativeLocalization.localizingCardNameVariables(
            Self.swarm, resolver: model.localeCatalogResolver
        ) else { return nil }
        return values["name"]
    }

    /// Lets the demand's main-actor hop run, then waits for the load it started.
    private func settle(_ model: AppModel) async {
        for _ in 0 ..< 100 where model.localeCatalogDeferredPackTask == nil {
            await Task.yield()
        }
        await model.localeCatalogDeferredPackTask?.value
    }

    private func cardNameRequests(
        _ transport: FixtureLocaleCatalogTransport,
        catalog: VendoredLocaleCatalog
    ) async -> [URL] {
        await transport.requests.filter(catalog.cardNameURLs.contains)
    }

    @Test("Cold start shows the server name, then the de name after the deferred load")
    func coldStartSwapsInLocalizedName() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let transport = catalog.transport()
        let model = await loadedModel(
            catalog: catalog, loader: LocaleCatalogLoader(transport: transport)
        )
        let pending = try #require(model.localeCatalog)
        #expect(pending.hasPendingDeferredPacks)
        #expect(await cardNameRequests(transport, catalog: catalog).isEmpty)

        #expect(shownName(model) == .string("Swarm of Rats"))
        #expect(shownName(model) == .string("Swarm of Rats"))
        await settle(model)

        #expect(shownName(model) == .string("Rattenschwarm"))
        #expect(model.localeCatalog?.identity == pending.identity)
        #expect(model.localeCatalogDeferredPacks?.state == .loaded)
        // Two renders demanded twice; the loads coalesced onto one fetch per chain locale.
        #expect(try await cardNameRequests(transport, catalog: catalog) == [
            catalog.url("de", "cardNames"), catalog.url("en", "cardNames"),
        ])
    }

    @Test("Cached deferred packs need no network for card names")
    func cachedDeferredPacksSkipNetwork() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let root = FileManager.default.temporaryDirectory.appending(
            path: "arkham-app-deferred-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let warm = LocaleCatalogLoader(
            transport: catalog.transport(), storage: FileLocaleCatalogStore(root: root)
        )
        let snapshot = try await catalog.load(warm, locale: "de")
        _ = try await catalog.loadDeferred(warm, snapshot: snapshot).get()

        let offline = catalog.transport(withheld: Set(catalog.chunkURLs.values))
        let model = await loadedModel(
            catalog: catalog,
            loader: LocaleCatalogLoader(
                transport: offline, storage: FileLocaleCatalogStore(root: root)
            )
        )
        #expect(shownName(model) == .string("Swarm of Rats"))
        await settle(model)

        #expect(shownName(model) == .string("Rattenschwarm"))
        #expect(await offline.requests == [catalog.manifestURL])
    }

    @Test("A failed deferred fetch keeps the catalog and server name and is not retried")
    func failedDeferredFetchIsSticky() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let transport = catalog.transport(withheld: catalog.cardNameURLs)
        let model = await loadedModel(
            catalog: catalog, loader: LocaleCatalogLoader(transport: transport)
        )
        #expect(shownName(model) == .string("Swarm of Rats"))
        await settle(model)
        #expect(model.localeCatalogDeferredPacks?.state == .failed)

        for _ in 0 ..< 3 {
            #expect(shownName(model) == .string("Swarm of Rats"))
            for _ in 0 ..< 10 {
                await Task.yield()
            }
        }
        #expect(model.localeCatalogDeferredPacks?.state == .failed)
        #expect(model.localeCatalogDeferredPackTask == nil)
        #expect(model.localeCatalogFailure == nil)
        #expect(model.localeCatalogResolver?.render(
            key: "continue", variables: .object([:])
        ) != nil)
        #expect(try await cardNameRequests(transport, catalog: catalog) == [
            catalog.url("de", "cardNames"),
        ])
    }

    @Test("A profile switch mid-load discards the deferred result")
    func profileSwitchDiscardsDeferredLoad() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let transport = GatedLocaleCatalogTransport(
            inner: catalog.transport(), gated: catalog.cardNameURLs
        )
        let model = await loadedModel(
            catalog: catalog, loader: LocaleCatalogLoader(transport: transport)
        )
        _ = shownName(model)
        for _ in 0 ..< 100 where await transport.heldRequests == 0 {
            await Task.yield()
        }
        #expect(await transport.heldRequests == 1)
        let inFlight = try #require(model.localeCatalogDeferredPackTask)

        model.selectProfile(.hosted)
        #expect(model.localeCatalogDeferredPacks == nil)
        await transport.release()
        await inFlight.value
        await model.flowTask?.value
        await model.localeCatalogTask?.value

        #expect(model.localeCatalog?.hasPendingDeferredPacks != false)
        #expect(model.localeCatalogDeferredPacks == nil)
    }

    @Test("A deferred result for a replaced snapshot (a locale switch) is not adopted")
    func staleIdentityIsFenced() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let loader = LocaleCatalogLoader(transport: catalog.transport())
        let model = await loadedModel(catalog: catalog, loader: loader)
        let request = try #require(model.localeCatalogRequest)
        let german = try #require(model.localeCatalog)
        let germanLoaded = try await catalog.loadDeferred(loader, snapshot: german).get()
        let english = try await catalog.load(loader, locale: "en")

        model.localeCatalog = english
        model.localeCatalogDeferredPacks = LocaleCatalogDeferredPackLoad(
            identity: german.identity, state: .loading
        )
        model.applyLocaleCatalogDeferredPacks(
            .success(germanLoaded), request: request, identity: german.identity
        )
        #expect(model.localeCatalog == english)

        model.localeCatalog = german
        model.applyLocaleCatalogDeferredPacks(
            .success(germanLoaded), request: request, identity: german.identity
        )
        #expect(model.localeCatalog == germanLoaded)
    }
}
