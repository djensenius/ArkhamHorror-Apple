@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves ``AssetDiskCache/get(_:)`` now participates in this cache's
/// cross-process/cross-instance advisory lock exactly like every write
/// path (``AssetDiskCache/set(_:payload:metadata:token:)``/
/// ``AssetDiskCache/touch(_:metadata:token:)``/
/// ``AssetDiskCache/remove(_:token:)``) already did — closing the
/// cumulative review's finding that a read bypassing this lock could
/// observe a concurrent writer's (this or another process's) entry
/// mid-publish and wrongly quarantine it. Companion to
/// `SecureCacheDirectoryLockingTests.swift`, which proves the underlying
/// `withExclusiveLock` primitive itself serializes across independent
/// instances; this proves ``AssetDiskCache/get(_:)`` actually contends for
/// that same lock rather than merely trusting the primitive is correct in
/// isolation.
@Suite("AssetDiskCache cross-instance read/write locking")
struct AssetDiskCacheCrossInstanceLockingTests {
    private func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("DiskCacheLockingScratch", isDirectory: true)
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

    @Test(
        """
        get(_:) blocks until a lock held directly by a genuinely independent \
        SecureCacheDirectory instance over the same directory is released, then returns the \
        correct, fully-committed entry -- proving it now contends for the same cross-process \
        lock every write path already does, rather than racing straight past a concurrent \
        writer's in-progress critical section
        """
    )
    func getBlocksOnLockHeldByIndependentInstance() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: AssetCacheLimits(
                maxEncodedBytes: 1_000_000,
                maxDimension: 8192,
                maxPixelCount: 32_000_000,
                memoryBudgetBytes: 10_000_000,
                diskBudgetBytes: 10_000_000
            ))
            let cacheKey = try key("01001")
            let payload = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            // A second, fully independent `SecureCacheDirectory` pointed
            // at the exact same directory -- standing in for a second
            // process/instance, exactly as
            // `SecureCacheDirectoryLockingTests` does -- holds the
            // cross-process lock directly for a deterministic interval,
            // simulating some other writer genuinely mid-critical-section.
            let independentHolder = try SecureCacheDirectory(
                directory: directory,
                fileManager: .default
            )
            let holderLockFD = try await independentHolder.acquireExclusiveLock()

            let holdDuration: UInt64 = 200_000_000
            let releaseTask = Task.detached {
                try await Task.sleep(nanoseconds: holdDuration)
                independentHolder.releaseExclusiveLock(holderLockFD)
            }

            let start = DispatchTime.now()
            // Started only once the other holder is confirmed to already
            // hold the lock (the `acquireExclusiveLock()` call above has
            // already returned), so this `get(_:)` call is guaranteed to
            // begin contending for the lock while it is genuinely held --
            // never racing to start before the hold even began.
            let result = await cache.get(cacheKey)
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

            _ = try await releaseTask.value
            #expect(
                elapsedNanoseconds >= holdDuration,
                """
                get(_:) returned before the concurrently-held lock was released -- it must \
                block for the lock's own duration, not race past it
                """
            )
            #expect(
                result?.payload == payload,
                "Once the lock is available, get(_:) must still return the correct, valid entry"
            )
        }
    }

    @Test(
        """
        Alternating get(_:) calls across two genuinely independent AssetDiskCache instances \
        sharing one directory always stamp a strictly increasing accessSequence for the same \
        entry -- each instance's own in-memory allocator is seeded only once at its own \
        construction, so without reseeding from the freshest on-disk value under the shared \
        lock a second instance could persist a duplicate or lower sequence than one the other \
        instance already wrote, corrupting LRU eviction order
        """
    )
    func alternatingCrossInstanceTouchesProduceStrictlyIncreasingSequence() async throws {
        try await withScratchDirectory { directory in
            let limits = AssetCacheLimits(
                maxEncodedBytes: 1_000_000,
                maxDimension: 8192,
                maxPixelCount: 32_000_000,
                memoryBudgetBytes: 10_000_000,
                diskBudgetBytes: 10_000_000
            )
            // Both instances are constructed while the directory is still
            // empty, so both seed their own private allocator from the
            // exact same (empty) starting point -- the scenario in which
            // a naive per-instance allocator with no on-disk reseeding
            // would most readily produce a collision or regression once
            // the two instances' reads/writes are interleaved.
            let first = try AssetDiskCache(directory: directory, limits: limits)
            let second = try AssetDiskCache(directory: directory, limits: limits)
            let cacheKey = try key("01001")
            let payload = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            try await first.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            var observedSequences: [Int] = []
            for iteration in 0 ..< 8 {
                let cache = iteration.isMultiple(of: 2) ? first : second
                let hit = try #require(
                    await cache.get(cacheKey),
                    "Expected a hit on every alternating read of a freshly seeded entry"
                )
                observedSequences.append(hit.metadata.accessSequence.value)
            }

            let strictlyIncreasing = zip(observedSequences, observedSequences.dropFirst())
                .allSatisfy { $0 < $1 }
            #expect(
                strictlyIncreasing,
                """
                Cross-instance accessSequence values must never repeat or regress: \
                \(observedSequences)
                """
            )
        }
    }
}
