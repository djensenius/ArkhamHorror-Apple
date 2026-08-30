@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves ``AssetDiskCache``'s LRU access-sequence counter is durably
/// monotonic *across the entire cache directory* -- across independent
/// keys, independent actor instances, and process restarts -- not merely
/// per-entry.
///
/// Before ``SecureCacheDirectory/allocateAccessSequence(atLeastAfter:)``,
/// each `AssetDiskCache` actor instance owned its own private, purely
/// in-memory ``AssetAccessSequenceAllocator``, seeded once (at that
/// instance's own startup recovery) from the highest sequence value found
/// among *its own* currently valid entries, and thereafter only ever
/// bumped to stay strictly after whatever value it personally observed
/// for the *exact entry* it was currently touching
/// (`allocate(atLeastAfter:)`). That closed the gap for repeated writes
/// to one key, but never for two *different* keys written by two
/// different, concurrently live instances: an instance seeded high (from
/// many recent entries) and one seeded low (freshly constructed) each
/// allocate from independent local counters, so a key the low-seeded
/// instance writes *after* the high-seeded instance already wrote a
/// *different* key could still be persisted with a strictly *lower*
/// sequence -- silently corrupting cache-wide LRU eviction order across
/// entries. This suite proves that defect is now closed by a single,
/// durable, shared counter file every instance reads-modifies-writes
/// under the same cross-process exclusive lock every other mutation
/// already requires.
@Suite("AssetDiskCache durable global access-sequence monotonicity")
struct AssetDiskCacheAccessSequenceTests {
    private func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("AccessSequenceMonotonicityScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private func key(_ rawCardCode: String) throws -> AssetCacheKey {
        let identifier = try AssetIdentifier.cardCode(rawCardCode)
        let assetKey = AssetKey(category: .card(.art, identifier))
        let candidates = AssetLocator.candidates(for: assetKey, digest: FakeDigestLookup())
        return AssetCacheKey(for: assetKey, candidates: candidates)
    }

    private func metadata(for cacheKey: AssetCacheKey, payload: Data) -> AssetCacheMetadata {
        AssetCacheMetadata(
            cacheKeyHex: cacheKey.digestHex,
            contentType: "image/png",
            encodedByteCount: payload.count,
            width: 4,
            height: 4,
            payloadSHA256Hex: AssetPayloadHasher.sha256Hex(payload),
            etag: nil,
            lastModified: nil,
            resolvedURLString: "https://example.com/\(cacheKey.digestHex)",
            insertedAt: Date(),
            accessSequence: AssetAccessSequence(0)
        )
    }

    /// The exact defect scenario: a "busy" instance writes many entries
    /// under key A (advancing its own local view of "next" high), then a
    /// second, freshly-constructed "quiet" instance -- which never
    /// observed any of that activity -- writes one *different* key B.
    /// Key B's freshly persisted sequence must still be strictly greater
    /// than every sequence key A's own writes already received, proving
    /// the counter is authoritative across keys and instances, not merely
    /// within one.
    @Test(
        """
        A freshly constructed instance writing a brand-new key is stamped with a sequence \
        strictly greater than every sequence a different, busier instance already persisted \
        for a completely different key
        """
    )
    func freshInstanceNewKeyExceedsBusyInstanceDifferentKey() async throws {
        try await withScratchDirectory { directory in
            let busyInstance = try AssetDiskCache(directory: directory, limits: .production)
            let keyA = try key("01001")
            for revision in 0 ..< 5 {
                let payload = Data([UInt8(revision)])
                try await busyInstance.set(
                    keyA, payload: payload, metadata: metadata(for: keyA, payload: payload)
                )
            }
            let finalA = try #require(await busyInstance.get(keyA))
            let highestFromBusyInstance = finalA.metadata.accessSequence

            // A genuinely new, independently constructed instance over
            // the exact same directory -- never sharing `busyInstance`'s
            // own in-memory state -- writing a completely different key.
            let quietInstance = try AssetDiskCache(directory: directory, limits: .production)
            let keyB = try key("01002")
            let payloadB = Data([9, 9, 9])
            try await quietInstance.set(
                keyB, payload: payloadB, metadata: metadata(for: keyB, payload: payloadB)
            )
            let storedB = try #require(await quietInstance.get(keyB))

            #expect(storedB.metadata.accessSequence > highestFromBusyInstance)
        }
    }

    /// Same shape as ``freshInstanceNewKeyExceedsBusyInstanceDifferentKey()``,
    /// but exercising `touch(_:metadata:)` (the LRU-bump-only path used
    /// after a 304 revalidation) rather than `set`, on the quiet
    /// instance's side, since that call site independently allocates a
    /// sequence too.
    @Test(
        """
        A freshly constructed instance's touch(_:metadata:) of an already-cached different key \
        is stamped with a sequence strictly greater than every sequence a busier instance \
        already persisted
        """
    )
    func freshInstanceTouchExceedsBusyInstanceDifferentKey() async throws {
        try await withScratchDirectory { directory in
            let busyInstance = try AssetDiskCache(directory: directory, limits: .production)
            let keyA = try key("01001")
            for revision in 0 ..< 5 {
                let payload = Data([UInt8(revision)])
                try await busyInstance.set(
                    keyA, payload: payload, metadata: metadata(for: keyA, payload: payload)
                )
            }
            let finalA = try #require(await busyInstance.get(keyA))
            let highestFromBusyInstance = finalA.metadata.accessSequence

            let quietInstance = try AssetDiskCache(directory: directory, limits: .production)
            let keyB = try key("01002")
            let payloadB = Data([7, 7, 7])
            try await quietInstance.set(
                keyB, payload: payloadB, metadata: metadata(for: keyB, payload: payloadB)
            )
            let storedB = try #require(await quietInstance.get(keyB))
            try await quietInstance.touch(keyB, metadata: storedB.metadata)
            let touchedB = try #require(await quietInstance.get(keyB))

            #expect(touchedB.metadata.accessSequence > highestFromBusyInstance)
        }
    }

    /// A restart (a fresh `AssetDiskCache` instance constructed over the
    /// same directory, simulating process relaunch) must never allocate a
    /// sequence that could collide with or fall behind one already
    /// persisted before the restart, proving the durable counter file
    /// itself (not merely one process's in-memory state) survives and
    /// remains authoritative across a restart.
    @Test(
        """
        A restart's freshly allocated sequence is always strictly greater than \
        every value persisted before it, even for a brand-new key never seen before the restart
        """
    )
    func restartAllocatesStrictlyAfterPriorPersistedValues() async throws {
        try await withScratchDirectory { directory in
            let beforeRestart = try AssetDiskCache(directory: directory, limits: .production)
            let keyA = try key("01001")
            let payloadA = Data([1, 2, 3])
            try await beforeRestart.set(
                keyA, payload: payloadA, metadata: metadata(for: keyA, payload: payloadA)
            )
            let storedA = try #require(await beforeRestart.get(keyA))
            let highestBeforeRestart = storedA.metadata.accessSequence

            let afterRestart = try AssetDiskCache(directory: directory, limits: .production)
            let keyC = try key("01003")
            let payloadC = Data([4, 5, 6])
            try await afterRestart.set(
                keyC, payload: payloadC, metadata: metadata(for: keyC, payload: payloadC)
            )
            let storedC = try #require(await afterRestart.get(keyC))

            #expect(storedC.metadata.accessSequence > highestBeforeRestart)
        }
    }

    /// The durable counter file itself must survive a whole-cache
    /// `removeAll()` -- unlike every actual entry -- so that a fresh
    /// entry written immediately afterward can never be assigned a
    /// sequence value low enough to collide with, or sort before, one
    /// written before the clear.
    @Test(
        """
        A key written immediately after removeAll() still receives a sequence \
        strictly greater than one written before the clear
        """
    )
    func sequenceStrictlyIncreasesAcrossRemoveAll() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: .production)
            let keyA = try key("01001")
            let payloadA = Data([1, 2, 3])
            try await cache.set(
                keyA, payload: payloadA, metadata: metadata(for: keyA, payload: payloadA)
            )
            let storedA = try #require(await cache.get(keyA))
            let highestBeforeClear = storedA.metadata.accessSequence

            try await cache.removeAll()

            let keyB = try key("01002")
            let payloadB = Data([4, 5, 6])
            try await cache.set(
                keyB, payload: payloadB, metadata: metadata(for: keyB, payload: payloadB)
            )
            let storedB = try #require(await cache.get(keyB))

            #expect(storedB.metadata.accessSequence > highestBeforeClear)
        }
    }
}
