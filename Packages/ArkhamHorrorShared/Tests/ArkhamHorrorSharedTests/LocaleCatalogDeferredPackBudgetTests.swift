@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Counts deferred-chunk staging writes and refuses the `failing`-th one.
private final class DeferredWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    let failing: Int

    init(failing: Int) {
        self.failing = failing
    }

    func allow(_ name: String) -> Bool {
        guard name == "chunk-update.json" else { return true }
        lock.lock()
        defer { lock.unlock() }
        writes += 1
        return writes != failing
    }
}

/// TASK-1.40 follow-up: a deferred-pack write stays inside the disk budget (net growth only,
/// rolled back on failure) and a deferred load counts the manifest against the catalog budget.
@Suite("Locale catalog deferred pack budgets")
struct LocaleCatalogDeferredPackBudgetTests {
    private static let budget = FileLocaleCatalogStore.maxDiskBytes

    private struct Fixture {
        let catalog: VendoredLocaleCatalog
        let root: URL
        let eager: LocaleCatalogSnapshot
        let full: LocaleCatalogSnapshot
        let entry: URL

        var deferredBytes: [String: Data] {
            catalog.bytesByDigest([
                LocaleCatalogChunkKey(locale: "de", pack: "cardNames"),
                LocaleCatalogChunkKey(locale: "en", pack: "cardNames"),
            ])
        }

        var deferredFiles: [URL] {
            deferredBytes.keys.map { entry.appending(path: "\($0).json") }
        }
    }

    /// An eager-only `de` entry on disk, plus the same snapshot with its card names.
    private func fixture() async throws -> Fixture {
        let catalog = try VendoredLocaleCatalog.make()
        let root = FileManager.default.temporaryDirectory.appending(
            path: "arkham-locale-catalog-budget-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let loader = LocaleCatalogLoader(
            transport: catalog.transport(), storage: FileLocaleCatalogStore(root: root)
        )
        let eager = try await catalog.load(loader, locale: "de")
        let full = try await catalog.loadDeferred(
            LocaleCatalogLoader(transport: catalog.transport()), snapshot: eager
        ).get()
        let entry = await FileLocaleCatalogStore(root: root).entryURL(for: eager.identity)
        return Fixture(catalog: catalog, root: root, eager: eager, full: full, entry: entry)
    }

    private func size(of directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: directory.path()).reduce(0) {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: directory.appending(path: $1).path()
            )
            return $0 + ((attributes[.size] as? Int) ?? 0)
        }
    }

    private func occupied(_ root: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: root.path()).reduce(0) {
            try $0 + size(of: root.appending(path: $1, directoryHint: .isDirectory))
        }
    }

    /// Grows `directory` to exactly `total` bytes with a sparse padding file.
    private func pad(_ directory: URL, to total: Int) throws {
        let padding = directory.appending(path: "padding.bin")
        let missing = try total - size(of: directory)
        #expect(missing >= 0)
        FileManager.default.createFile(atPath: padding.path(), contents: nil)
        let handle = try FileHandle(forWritingTo: padding)
        try handle.truncate(atOffset: UInt64(missing))
        try handle.close()
    }

    /// A least-recently-used foreign entry of exactly `total` bytes.
    private func foreignEntry(in root: URL, total: Int) throws -> URL {
        let entry = root.appending(path: String(repeating: "a", count: 64))
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let record = """
        {"endpoint":"https://other.example.test/locale-catalog/manifest.json",\
        "catalogRevision":"other","locale":"en",\
        "manifestSha256":"\(String(repeating: "b", count: 64))","accessedAt":0}
        """
        try Data(record.utf8).write(to: entry.appending(path: "entry.json"))
        try pad(entry, to: total)
        return entry
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path())
    }

    @Test("A deferred write evicts least-recently-used entries to fit")
    func deferredWriteEvicts() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let foreign = try foreignEntry(
            in: fixture.root, total: Self.budget - size(of: fixture.entry)
        )

        await FileLocaleCatalogStore(root: fixture.root).storeDeferred(
            snapshot: fixture.full, chunkBytes: fixture.deferredBytes
        )

        #expect(!exists(foreign))
        #expect(fixture.deferredFiles.allSatisfy(exists))
        #expect(try occupied(fixture.root) <= Self.budget)
        let cold = FileLocaleCatalogStore(root: fixture.root)
        #expect(await cold.loadDeferred(snapshot: fixture.eager) == fixture.full)
    }

    @Test("A deferred write that cannot fit even alone writes nothing")
    func oversizeDeferredWriteIsRefused() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try pad(fixture.entry, to: Self.budget - 1)

        await FileLocaleCatalogStore(root: fixture.root).storeDeferred(
            snapshot: fixture.full, chunkBytes: fixture.deferredBytes
        )

        #expect(!fixture.deferredFiles.contains(where: exists))
        #expect(!exists(fixture.entry.appending(path: "chunk-update.json")))
        #expect(try occupied(fixture.root) == Self.budget - 1)
        let cold = FileLocaleCatalogStore(root: fixture.root)
        #expect(await cold.load(
            identity: fixture.eager.identity, manifest: fixture.catalog.manifest
        ) == fixture.eager)
        #expect(await cold.loadDeferred(snapshot: fixture.eager) == nil)
    }

    @Test("Repairing corrupt deferred files reserves only the net growth")
    func repairReservesNetGrowth() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for (digest, bytes) in fixture.deferredBytes {
            var corrupt = bytes
            corrupt[corrupt.startIndex] ^= 0x01
            try corrupt.write(to: fixture.entry.appending(path: "\(digest).json"))
        }
        // Already exactly at budget: the repair replaces same-sized files, so it still fits.
        try pad(fixture.entry, to: Self.budget)

        await FileLocaleCatalogStore(root: fixture.root).storeDeferred(
            snapshot: fixture.full, chunkBytes: fixture.deferredBytes
        )

        for (digest, bytes) in fixture.deferredBytes {
            #expect(try Data(contentsOf: fixture.entry.appending(path: "\(digest).json")) == bytes)
        }
        #expect(try occupied(fixture.root) == Self.budget)
        let cold = FileLocaleCatalogStore(root: fixture.root)
        #expect(await cold.loadDeferred(snapshot: fixture.eager) == fixture.full)
    }

    @Test("A failed second chunk write removes the first and stays within budget")
    func failedDeferredWriteRollsBack() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // One byte under budget: the first published chunk alone would push it over unless
        // the planned eviction has run.
        let foreign = try foreignEntry(
            in: fixture.root, total: Self.budget - 1 - size(of: fixture.entry)
        )
        let failure = DeferredWriteFailure(failing: 2)

        let gate: LocaleCatalogPOSIX.WriteGate = { failure.allow($0) }
        await LocaleCatalogPOSIX.$writeGate.withValue(gate) {
            await FileLocaleCatalogStore(root: fixture.root).storeDeferred(
                snapshot: fixture.full, chunkBytes: fixture.deferredBytes
            )
        }

        #expect(!fixture.deferredFiles.contains(where: exists))
        #expect(!exists(fixture.entry.appending(path: "chunk-update.json")))
        // Evictions run before any write, so the budget holds even if the rollback could not.
        #expect(!exists(foreign))
        #expect(try occupied(fixture.root) <= Self.budget)
        let cold = FileLocaleCatalogStore(root: fixture.root)
        #expect(await cold.load(
            identity: fixture.eager.identity, manifest: fixture.catalog.manifest
        ) == fixture.eager)
        #expect(await cold.loadDeferred(snapshot: fixture.eager) == nil)
    }

    @Test("A deferred load counts the manifest against the catalog budget")
    func deferredLoadCountsManifest() async throws {
        let catalog = try VendoredLocaleCatalog.make()
        let eager = try await catalog.load(
            LocaleCatalogLoader(transport: catalog.transport()), locale: "de"
        )
        #expect(eager.manifestByteCount == catalog.manifestBytes.count)
        let chunkTotal = (eager.chainChunkLocations ?? []).reduce(0) { $0 + $1.descriptor.bytes }
        var chunks: [LocaleCatalogChunkKey: LocaleCatalogChunk] = [:]
        for location in eager.heldChunkLocations {
            chunks[location.key] = try catalog.chunk(location.key)
        }
        /// The same catalog as if its manifest were large enough that manifest plus every
        /// chunk is one byte over the limit, even though the chunks alone are within it.
        func snapshot(manifestBytes: Int) -> LocaleCatalogSnapshot {
            LocaleCatalogSnapshot(
                identity: eager.identity, manifest: eager.manifest, chunks: chunks,
                manifestByteCount: manifestBytes
            )
        }
        let limit = LocaleCatalogLimits.maxCatalogBytes
        let transport = catalog.transport()
        let loader = LocaleCatalogLoader(transport: transport)

        let over = snapshot(manifestBytes: limit - chunkTotal + 1)
        #expect(await catalog.loadDeferred(loader, snapshot: over) == .failure(.tooLarge))
        // Refused at the descriptor-size check, before the chunk that overflows is fetched.
        #expect(try await !transport.requests.contains(catalog.url("en", "cardNames")))

        let exact = snapshot(manifestBytes: limit - chunkTotal)
        let loaded = try await catalog.loadDeferred(loader, snapshot: exact).get()
        #expect(loaded.cardName("01159") == "Rattenschwarm")
        #expect(loaded.manifestByteCount == limit - chunkTotal)
    }
}
