@testable import ArkhamHorrorShared
import Darwin
import Foundation
import Testing

private struct ValidatedSyntheticCatalog {
    let documents: SyntheticLocaleCatalogDocuments
    let manifest: LocaleCatalogManifest
    let snapshot: LocaleCatalogSnapshot
}

@Suite("Locale catalog store")
struct LocaleCatalogStoreTests {
    private func validatedCatalog(
        manifestPath: String = "/locale-catalog/manifest.json"
    ) async throws -> ValidatedSyntheticCatalog {
        let documents = try SyntheticLocaleCatalogDocuments.make(manifestPath: manifestPath)
        let value = try LosslessJSONParser.parse(documents.manifestBytes)
        let manifest = try LocaleCatalogManifest.validate(
            value, against: documents.advertisement
        ).get()
        let snapshot = try await LocaleCatalogLoader(
            transport: FixtureLocaleCatalogTransport(responses: [
                documents.manifestURL: documents.response(
                    data: documents.manifestBytes, url: documents.manifestURL
                ),
                documents.chunkURL: documents.response(
                    data: documents.chunkBytes, url: documents.chunkURL
                ),
            ])
        ).load(
            advertisement: documents.advertisement,
            profile: documents.profile,
            preferredLanguages: ["en"]
        ).get()
        return ValidatedSyntheticCatalog(
            documents: documents, manifest: manifest, snapshot: snapshot
        )
    }

    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "arkham-locale-catalog-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func cacheBytes(for documents: SyntheticLocaleCatalogDocuments) -> [String: Data] {
        [LocaleCatalogLoader.sha256Hex(documents.chunkBytes): documents.chunkBytes]
    }

    private func persist(
        _ store: FileLocaleCatalogStore,
        catalog: ValidatedSyntheticCatalog
    ) async {
        await store.store(
            snapshot: catalog.snapshot,
            manifestBytes: catalog.documents.manifestBytes,
            chunkBytes: cacheBytes(for: catalog.documents)
        )
    }

    @Test("Concurrent reads coalesce through the actor-backed memory tier")
    func concurrentReadsReturnOneVerifiedSnapshot() async throws {
        let catalog = try await validatedCatalog()
        let root = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FileLocaleCatalogStore(root: root)
        await persist(writer, catalog: catalog)
        let store = FileLocaleCatalogStore(root: root)
        async let first = store.load(
            identity: catalog.snapshot.identity, manifest: catalog.manifest
        )
        async let second = store.load(
            identity: catalog.snapshot.identity, manifest: catalog.manifest
        )
        let results = await [first, second]
        #expect(results.allSatisfy { $0 == catalog.snapshot })
    }

    @Test("Corrupt and foreign cache entries are discarded instead of reused")
    func corruptAndForeignEntriesFailClosed() async throws {
        let catalog = try await validatedCatalog()
        let root = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileLocaleCatalogStore(root: root)
        await persist(store, catalog: catalog)
        let endpoint = try #require(URL(
            string: "https://other.example.test/locale-catalog/manifest.json"
        ))
        let foreign = LocaleCatalogIdentity(
            endpoint: endpoint,
            catalogRevision: catalog.snapshot.identity.catalogRevision,
            locale: catalog.snapshot.identity.locale,
            manifestSha256: catalog.snapshot.identity.manifestSha256
        )
        let foreignSnapshot = await store.load(identity: foreign, manifest: catalog.manifest)
        #expect(foreignSnapshot == nil)

        let entry = await store.entryURL(for: catalog.snapshot.identity)
        try Data("broken".utf8).write(to: entry.appending(path: "manifest.json"))
        let coldStore = FileLocaleCatalogStore(root: root)
        let corruptedSnapshot = await coldStore.load(
            identity: catalog.snapshot.identity, manifest: catalog.manifest
        )
        #expect(corruptedSnapshot == nil)
        #expect(!FileManager.default.fileExists(atPath: entry.path()))
    }

    @Test("Symlink cache roots and entries never follow or delete external sentinels")
    func symlinkRootsAndEntriesFailClosed() async throws {
        let catalog = try await validatedCatalog()
        let manager = FileManager.default
        let parent = scratchDirectory()
        let external = scratchDirectory()
        let rootLink = parent.appendingPathComponent("root-link", isDirectory: false)
        defer {
            try? manager.removeItem(at: parent)
            try? manager.removeItem(at: external)
        }
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        try manager.createDirectory(at: external, withIntermediateDirectories: true)
        let sentinel = external.appending(path: "sentinel.txt")
        try Data("untouched".utf8).write(to: sentinel)
        try manager.createSymbolicLink(at: rootLink, withDestinationURL: external)

        let linkedRootStore = FileLocaleCatalogStore(root: rootLink)
        await persist(linkedRootStore, catalog: catalog)
        let coldLinkedRootStore = FileLocaleCatalogStore(root: rootLink)
        let rootSnapshot = await coldLinkedRootStore.load(
            identity: catalog.snapshot.identity, manifest: catalog.manifest
        )
        #expect(rootSnapshot == nil)
        #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))

        let root = parent.appendingPathComponent("root", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let entry = root.appendingPathComponent(
            FileLocaleCatalogStore.directoryName(for: catalog.snapshot.identity),
            isDirectory: false
        )
        try manager.createSymbolicLink(at: entry, withDestinationURL: external)
        let linkedEntryStore = FileLocaleCatalogStore(root: root)
        let entrySnapshot = await linkedEntryStore.load(
            identity: catalog.snapshot.identity, manifest: catalog.manifest
        )
        #expect(entrySnapshot == nil)
        #expect(!manager.fileExists(atPath: entry.path()))
        #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))

        try Data("not a directory".utf8).write(to: entry)
        let regularEntryStore = FileLocaleCatalogStore(root: root)
        let regularSnapshot = await regularEntryStore.load(
            identity: catalog.snapshot.identity, manifest: catalog.manifest
        )
        #expect(regularSnapshot == nil)
        #expect(!manager.fileExists(atPath: entry.path()))
    }

    @Test("Stale staging objects are reclaimed while an oversized invalid root is refused")
    func stagingCleanupAndFloodBound() async throws {
        let catalog = try await validatedCatalog()
        let manager = FileManager.default
        let root = scratchDirectory()
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0 ..< FileLocaleCatalogStore.maxDiskEntries {
            let staging = root.appending(
                path: "staging-interrupted-\(index)",
                directoryHint: .isDirectory
            )
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            try Data("partial".utf8).write(to: staging.appending(path: "partial.json"))
        }
        let store = FileLocaleCatalogStore(root: root)
        await persist(store, catalog: catalog)
        let remaining = try manager.contentsOfDirectory(atPath: root.path())
        #expect(remaining.allSatisfy { !$0.hasPrefix("staging-") })
        let destination = await store.entryURL(for: catalog.snapshot.identity)
        #expect(manager.fileExists(atPath: destination.path()))

        let flooded = scratchDirectory()
        defer { try? manager.removeItem(at: flooded) }
        try manager.createDirectory(at: flooded, withIntermediateDirectories: true)
        for index in 0 ... FileLocaleCatalogStore.maxDiskEntries + 1 {
            try Data("x".utf8).write(to: flooded.appending(path: "invalid-\(index)"))
        }
        let floodedStore = FileLocaleCatalogStore(root: flooded)
        await persist(floodedStore, catalog: catalog)
        let floodedDestination = await floodedStore.entryURL(for: catalog.snapshot.identity)
        #expect(!manager.fileExists(atPath: floodedDestination.path()))
    }

    @Test("Repeated failed disk-cache paths return per-store descriptor accounting to zero")
    func failedCachePathsDoNotLeakDescriptors() async throws {
        let catalog = try await validatedCatalog()
        let manager = FileManager.default
        let root = scratchDirectory()
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let tracker = LocaleCatalogDescriptorTracker()
        for _ in 0 ..< 64 {
            let store = FileLocaleCatalogStore(root: root, descriptorTracker: tracker)
            _ = await store.load(identity: catalog.snapshot.identity, manifest: catalog.manifest)
            await persist(store, catalog: catalog)
            let entry = await store.entryURL(for: catalog.snapshot.identity)
            try Data("corrupt".utf8).write(to: entry.appending(path: "manifest.json"))
        }
        #expect(tracker.isClean)
    }

    @Test("A failed publish preserves every entry selected for eviction")
    func failedPublishPreservesEvictions() async throws {
        var catalogs: [ValidatedSyntheticCatalog] = []
        for index in 0 ... FileLocaleCatalogStore.maxDiskEntries {
            let catalog = try await validatedCatalog(
                manifestPath:
                "https://catalog-\(index).example.test/locale-catalog/manifest.json"
            )
            catalogs.append(catalog)
        }
        let root = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileLocaleCatalogStore(root: root)
        for catalog in catalogs.dropLast() {
            await persist(store, catalog: catalog)
        }
        #expect(await store.diskEntries().count == FileLocaleCatalogStore.maxDiskEntries)

        let replacement = catalogs[catalogs.count - 1]
        let destination = FileLocaleCatalogStore.directoryName(for: replacement.snapshot.identity)
        let moveGate: LocaleCatalogPOSIX.MoveGate = { source, target in
            !(source.hasPrefix("staging-") && target == destination)
        }
        await LocaleCatalogPOSIX.$moveGate.withValue(moveGate) {
            await persist(store, catalog: replacement)
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path())
        #expect(names.count == FileLocaleCatalogStore.maxDiskEntries)
        #expect(names.allSatisfy { !$0.hasPrefix("rollback-") && !$0.hasPrefix("staging-") })
        let coldStore = FileLocaleCatalogStore(root: root)
        for catalog in catalogs.dropLast() {
            #expect(await coldStore.load(
                identity: catalog.snapshot.identity, manifest: catalog.manifest
            ) == catalog.snapshot)
        }
    }

    @Test("Descriptor tracker exposes duplicate, failed, unknown, and reusable descriptor state")
    func descriptorTrackerReportsEveryViolation() {
        let tracker = LocaleCatalogDescriptorTracker()
        tracker.opened(41)
        tracker.opened(41)
        tracker.closed(41, succeeded: false, errorCode: EBADF)
        tracker.closed(41, succeeded: true, errorCode: 0)
        tracker.closed(41, succeeded: true, errorCode: 0)
        #expect(tracker.outstandingCount == 0)
        #expect(tracker.violationCount == 3)

        let reuse = LocaleCatalogDescriptorTracker()
        reuse.opened(41)
        reuse.closed(41, succeeded: true, errorCode: 0)
        reuse.opened(41)
        reuse.closed(41, succeeded: true, errorCode: 0)
        #expect(reuse.isClean)
    }

    @Test("Tracker absence never suppresses the real Darwin close")
    func closeWithoutTrackerStillClosesDescriptor() {
        let descriptor = Darwin.open("/dev/null", O_RDONLY)
        #expect(descriptor >= 0)
        LocaleCatalogPOSIX.$tracker.withValue(nil) {
            LocaleCatalogPOSIX.closeDescriptor(descriptor)
        }
        #expect(fcntl(descriptor, F_GETFD) == -1)
        #expect(errno == EBADF)
    }
}

extension LocaleCatalogStoreTests {
    @Test("An interrupted atomic replacement keeps a canonical entry")
    func interruptedReplacementKeepsCanonicalEntry() async throws {
        let catalog = try await validatedCatalog()
        let manager = FileManager.default
        let root = scratchDirectory()
        defer { try? manager.removeItem(at: root) }
        let store = FileLocaleCatalogStore(root: root)
        await persist(store, catalog: catalog)

        let destination = await store.entryURL(for: catalog.snapshot.identity)
        let stagingName = "staging-interrupted-\(UUID().uuidString)"
        let staging = root.appending(path: stagingName, directoryHint: .isDirectory)
        try manager.copyItem(at: destination, to: staging)
        let rootFD = try #require(LocaleCatalogPOSIX.openDirectory(path: root.path()))
        let swapped = LocaleCatalogPOSIX.swap(
            parent: rootFD,
            first: stagingName,
            second: destination.lastPathComponent
        )
        LocaleCatalogPOSIX.closeDescriptor(rootFD)
        #expect(swapped)
        #expect(manager.fileExists(atPath: destination.path()))
        #expect(manager.fileExists(atPath: staging.path()))

        let coldStore = FileLocaleCatalogStore(root: root)
        #expect(await coldStore.diskEntries().count == 1)
        #expect(!manager.fileExists(atPath: staging.path()))
        #expect(await coldStore.load(
            identity: catalog.snapshot.identity,
            manifest: catalog.manifest
        ) == catalog.snapshot)
    }

    @Test("A failed atomic replacement preserves the existing entry")
    func failedReplacementPreservesExistingEntry() async throws {
        let catalog = try await validatedCatalog()
        let manager = FileManager.default
        let root = scratchDirectory()
        defer { try? manager.removeItem(at: root) }
        let store = FileLocaleCatalogStore(root: root)
        await persist(store, catalog: catalog)

        let destination = FileLocaleCatalogStore.directoryName(for: catalog.snapshot.identity)
        let moveGate: LocaleCatalogPOSIX.MoveGate = { source, target in
            !(source.hasPrefix("staging-") && target == destination)
        }
        await LocaleCatalogPOSIX.$moveGate.withValue(moveGate) {
            await persist(store, catalog: catalog)
        }

        let names = try manager.contentsOfDirectory(atPath: root.path())
        #expect(names == [destination])
        let coldStore = FileLocaleCatalogStore(root: root)
        #expect(await coldStore.load(
            identity: catalog.snapshot.identity,
            manifest: catalog.manifest
        ) == catalog.snapshot)
    }
}
