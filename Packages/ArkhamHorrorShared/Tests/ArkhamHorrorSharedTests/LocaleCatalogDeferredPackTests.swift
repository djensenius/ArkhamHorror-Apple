@testable import ArkhamHorrorShared
import Foundation
import Testing

/// TASK-1.40: the `cardNames` packs (over a megabyte per locale since 0.1.60) are not part of
/// the initial catalog load; they are fetched, verified and cached on first need.
@Suite("Locale catalog deferred packs")
struct LocaleCatalogDeferredPackTests {
    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "arkham-locale-catalog-deferred-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    @Test("A cold load fetches no cardNames chunk and the catalog is usable without them")
    func coldLoadSkipsCardNames() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let transport = catalog.transport()
        let snapshot = try await catalog.load(
            LocaleCatalogLoader(transport: transport), locale: "de"
        )

        #expect(snapshot.isComplete)
        #expect(snapshot.localeChain == ["de", "en"])
        #expect(try await transport.requests == [
            catalog.manifestURL,
            catalog.url("de", "core"),
            catalog.url("en", "core"),
            catalog.url("en", "nightOfTheZealot"),
        ])
        #expect(Set(snapshot.pendingDeferredChunks.map(\.key)) == [
            LocaleCatalogChunkKey(locale: "de", pack: "cardNames"),
            LocaleCatalogChunkKey(locale: "en", pack: "cardNames"),
        ])
        #expect(snapshot.cardName("01159") == nil)
        let rendered = LocaleCatalogResolver(snapshot: snapshot).render(
            key: "continue", variables: .object([:])
        )
        #expect((try? rendered.get()) != nil)
    }

    @Test("Deferred loading fetches every chain cardNames pack once and adds them atomically")
    func deferredLoadFetchesChainCardNames() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let transport = catalog.transport()
        let loader = LocaleCatalogLoader(transport: transport)
        let snapshot = try await catalog.load(loader, locale: "de")
        let loaded = try await catalog.loadDeferred(loader, snapshot: snapshot).get()

        #expect(try await Array(transport.requests.dropFirst(4)) == [
            catalog.url("de", "cardNames"), catalog.url("en", "cardNames"),
        ])
        #expect(loaded.identity == snapshot.identity)
        #expect(!loaded.hasPendingDeferredPacks)
        #expect(loaded.isComplete)
        #expect(loaded.cardName("01159") == "Rattenschwarm")
        #expect(loaded.cardName("01003") != nil)
        // Nothing is pending any more, so a second call is a no-op without the network.
        #expect(await catalog.loadDeferred(loader, snapshot: loaded) == .success(loaded))
        #expect(await transport.requests.count == 6)
    }

    @Test("The card-only pl locale loads through en and gets its own cardNames later")
    func cardOnlyLocaleLoads() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let transport = catalog.transport()
        let loader = LocaleCatalogLoader(transport: transport)
        let snapshot = try await catalog.load(loader, locale: "pl")

        #expect(snapshot.identity.locale == "pl")
        #expect(snapshot.localeChain == ["pl", "en"])
        #expect(try await transport.requests == [
            catalog.manifestURL,
            catalog.url("en", "core"),
            catalog.url("en", "nightOfTheZealot"),
        ])
        let loaded = try await catalog.loadDeferred(loader, snapshot: snapshot).get()
        #expect(loaded.cardName("01159") == "Rój szczurów")
    }

    @Test("A deferred chunk whose bytes miss the pinned digest is rejected")
    func deferredDigestMismatchFails() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let tampered = try catalog.url("en", "cardNames")
        let original = try #require(
            catalog.chunkBytes[LocaleCatalogChunkKey(locale: "en", pack: "cardNames")]
        )
        var forged = original
        forged[forged.startIndex + 2] ^= 0x01
        let transport = catalog.transport(overrides: [tampered: forged])
        let loader = LocaleCatalogLoader(transport: transport)
        let snapshot = try await catalog.load(loader, locale: "de")

        let result = await catalog.loadDeferred(loader, snapshot: snapshot)
        #expect(result == .failure(.chunkDigestMismatch))
        #expect(snapshot.cardName("01159") == nil)
    }

    @Test("A deferred load for another endpoint's snapshot is refused before any request")
    func deferredLoadIsBoundToSnapshotEndpoint() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let transport = catalog.transport()
        let loader = LocaleCatalogLoader(transport: transport)
        let snapshot = try await catalog.load(loader, locale: "de")
        let other = try ServerProfile.custom(
            displayName: "Other", rawURL: "https://other.example.test/profile-prefix"
        )
        let result = await loader.loadDeferredPacks(
            for: snapshot, advertisement: catalog.advertisement, profile: other
        )
        #expect(result == .failure(.malformedManifest))
        #expect(await transport.requests.count == 4)
    }

    @Test("adding(chunks:) accepts only the exact pending deferred set")
    func addingRequiresExactPendingSet() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let snapshot = try await catalog.load(
            LocaleCatalogLoader(transport: catalog.transport()), locale: "de"
        )
        let full = try await catalog.loadDeferred(
            LocaleCatalogLoader(transport: catalog.transport()), snapshot: snapshot
        ).get()
        let deKey = LocaleCatalogChunkKey(locale: "de", pack: "cardNames")
        let enKey = LocaleCatalogChunkKey(locale: "en", pack: "cardNames")
        let deChunk = try catalog.chunk(deKey)
        let enChunk = try catalog.chunk(enKey)

        #expect(snapshot.adding(chunks: [deKey: deChunk]) == nil)
        #expect(snapshot.adding(chunks: [deKey: enChunk, enKey: enChunk]) == nil)
        #expect(full.adding(chunks: [:]) == nil)
        #expect(snapshot.adding(chunks: [deKey: deChunk, enKey: enChunk]) == full)
    }

    @Test("A deferred load is cached in the same entry and later served without the network")
    func deferredChunksAreCached() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let root = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let warm = LocaleCatalogLoader(
            transport: catalog.transport(), storage: FileLocaleCatalogStore(root: root)
        )
        let snapshot = try await catalog.load(warm, locale: "de")
        let expected = try await catalog.loadDeferred(warm, snapshot: snapshot).get()

        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path())
        #expect(entries == [FileLocaleCatalogStore.directoryName(for: snapshot.identity)])

        // A fresh process: the manifest is still fetched (its digest gates the cache), but
        // every chunk, including the deferred ones, comes from disk.
        let offline = catalog.transport(withheld: Set(catalog.chunkURLs.values))
        let cold = LocaleCatalogLoader(
            transport: offline, storage: FileLocaleCatalogStore(root: root)
        )
        let cached = try await catalog.load(cold, locale: "de")
        #expect(cached.hasPendingDeferredPacks)
        let loaded = try await catalog.loadDeferred(cold, snapshot: cached).get()
        #expect(loaded == expected)
        #expect(loaded.cardName("01159") == "Rattenschwarm")
        #expect(await offline.requests == [catalog.manifestURL])
    }

    @Test("A cache entry that already holds the cardNames files loads with no migration")
    func preexistingFullEntryLoads() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let root = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await catalog.load(
            LocaleCatalogLoader(transport: catalog.transport()), locale: "de"
        )
        let full = try await catalog.loadDeferred(
            LocaleCatalogLoader(transport: catalog.transport()), snapshot: snapshot
        ).get()
        // The layout an eager-only build wrote: every chain chunk in one entry.
        await FileLocaleCatalogStore(root: root).store(
            snapshot: full,
            manifestBytes: catalog.manifestBytes,
            chunkBytes: catalog.bytesByDigest(Array(catalog.chunkBytes.keys))
        )
        let entry = await FileLocaleCatalogStore(root: root).entryURL(for: snapshot.identity)
        let deBytes = try #require(
            catalog.chunkBytes[LocaleCatalogChunkKey(locale: "de", pack: "cardNames")]
        )
        let deFile = entry.appending(path: "\(LocaleCatalogLoader.sha256Hex(deBytes)).json")
        #expect(FileManager.default.fileExists(atPath: deFile.path()))

        let store = FileLocaleCatalogStore(root: root)
        let restored = try #require(await store.load(
            identity: snapshot.identity, manifest: catalog.manifest
        ))
        #expect(restored == snapshot)
        let loaded = try #require(await store.loadDeferred(snapshot: restored))
        #expect(loaded == full)
    }

    @Test("A tampered cached cardNames file is re-hashed, refused, and refetched")
    func tamperedCachedDeferredChunkIsRefused() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let root = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = LocaleCatalogLoader(
            transport: catalog.transport(), storage: FileLocaleCatalogStore(root: root)
        )
        let snapshot = try await catalog.load(loader, locale: "de")
        let full = try await catalog.loadDeferred(loader, snapshot: snapshot).get()
        let deBytes = try #require(
            catalog.chunkBytes[LocaleCatalogChunkKey(locale: "de", pack: "cardNames")]
        )
        let entry = await FileLocaleCatalogStore(root: root).entryURL(for: snapshot.identity)
        let file = entry.appending(path: "\(LocaleCatalogLoader.sha256Hex(deBytes)).json")
        var forged = deBytes
        forged[forged.startIndex + 2] ^= 0x01
        try forged.write(to: file)

        let store = FileLocaleCatalogStore(root: root)
        let restored = try #require(await store.load(
            identity: snapshot.identity, manifest: catalog.manifest
        ))
        #expect(await store.loadDeferred(snapshot: restored) == nil)

        // The network path rewrites the bad file, and the next cold read verifies it.
        let transport = catalog.transport()
        let refetch = LocaleCatalogLoader(transport: transport, storage: store)
        #expect(await catalog.loadDeferred(refetch, snapshot: restored) == .success(full))
        #expect(try Data(contentsOf: file) == deBytes)
        let reread = await FileLocaleCatalogStore(root: root).loadDeferred(snapshot: restored)
        #expect(reread == full)
    }
}
