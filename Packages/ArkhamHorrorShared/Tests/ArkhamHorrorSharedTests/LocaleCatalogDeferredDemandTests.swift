@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Counts deferred-pack demands from a resolver; the hook is `@Sendable`.
final class DeferredDemandCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var demands: Int {
        lock.withLock { calls }
    }

    func record() {
        lock.withLock { calls += 1 }
    }
}

/// TASK-1.40: a `cardNames.*` miss while the packs are still pending asks the owner to load
/// them, and the label keeps the server-sent name meanwhile, as the web does.
@Suite("Locale catalog deferred pack demand")
struct LocaleCatalogDeferredDemandTests {
    /// A synthetic entry whose whole text is a static link into the deferred pack (see
    /// `Fixtures/LegacyContract/PROVENANCE.md`).
    private static let linkEntries = """
    {"story.cardLink":{"form":"message","nodes":[{"type":"linked",\
    "target":{"kind":"static","key":"cardNames.01159"},"modifier":null}],"variables":[]}}
    """

    private static let swarmValues: [String: JSONValue] = [
        "name": .string("Swarm of Rats"), "__name": .string("01159"),
    ]

    private func snapshots() async throws -> (
        pending: LocaleCatalogSnapshot,
        loaded: LocaleCatalogSnapshot
    ) {
        let catalog = try VendoredLocaleCatalog.make()
        let loader = LocaleCatalogLoader(transport: catalog.transport())
        let pending = try await catalog.load(loader, locale: "de")
        let loaded = try await catalog.loadDeferred(loader, snapshot: pending).get()
        return (pending, loaded)
    }

    private func resolver(
        _ snapshot: LocaleCatalogSnapshot, counter: DeferredDemandCounter
    ) -> LocaleCatalogResolver {
        LocaleCatalogResolver(snapshot: snapshot, deferredPackDemand: { counter.record() })
    }

    @Test("A cardNames miss with packs pending asks for them and keeps the server name")
    func pendingMissDemandsAndKeepsServerName() async throws {
        let counter = DeferredDemandCounter()
        let resolver = try await resolver(snapshots().pending, counter: counter)

        #expect(StoryNarrativeLocalization.localizedCardNames(
            in: Self.swarmValues, resolver: resolver
        ).isEmpty)
        #expect(StoryNarrativeLocalization.localizingCardNameVariables(
            .object(Self.swarmValues), resolver: resolver
        ) == .object(Self.swarmValues))
        #expect(counter.demands == 2)
    }

    @Test("A cardNames hit, a miss with nothing pending, and other misses ask for nothing")
    func hitsAndUnrelatedMissesDoNotDemand() async throws {
        let counter = DeferredDemandCounter()
        let (pending, loaded) = try await snapshots()
        let loadedResolver = resolver(loaded, counter: counter)

        #expect(StoryNarrativeLocalization.localizedCardNames(
            in: Self.swarmValues, resolver: loadedResolver
        ) == ["name": "Rattenschwarm"])
        #expect(loadedResolver.render(
            key: "cardNames.99999", variables: .object([:])
        ) == .failure(.missingKey))
        #expect(resolver(pending, counter: counter).render(
            key: "label.notInCatalog", variables: .object([:])
        ) == .failure(.missingKey))
        #expect(counter.demands == 0)
    }

    @Test("A link into a pending cardNames pack asks for it")
    func linkMissDemands() async throws {
        let counter = DeferredDemandCounter()
        let pending = try await snapshots().pending
        let bytes = Data("""
        {"schemaVersion":"1.0.0","locale":"de","fallback":"en","pack":"syntheticLinks",\
        "entries":\(Self.linkEntries)}
        """.utf8)
        let chunk = try LocaleCatalogChunk.validate(
            LosslessJSONParser.parse(bytes), expectedLocale: "de", expectedFallback: "en",
            expectedPack: "syntheticLinks", expectedKeys: 1, expectedUnsupportedKeys: 0
        ).get()
        var chunks: [LocaleCatalogChunkKey: LocaleCatalogChunk] = [
            LocaleCatalogChunkKey(locale: "de", pack: "syntheticLinks"): chunk,
        ]
        let catalog = try VendoredLocaleCatalog.make()
        for key in [("de", "core"), ("en", "core"), ("en", "nightOfTheZealot")] {
            let chunkKey = LocaleCatalogChunkKey(locale: key.0, pack: key.1)
            chunks[chunkKey] = try catalog.chunk(chunkKey)
        }
        let linked = LocaleCatalogSnapshot(
            identity: pending.identity, manifest: pending.manifest, chunks: chunks
        )

        #expect(resolver(linked, counter: counter).render(
            key: "story.cardLink", variables: .object([:])
        ) == .failure(.missingKey))
        #expect(counter.demands == 1)
    }
}
