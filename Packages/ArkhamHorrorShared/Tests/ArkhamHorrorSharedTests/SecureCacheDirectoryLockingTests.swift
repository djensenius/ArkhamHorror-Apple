@testable import ArkhamHorrorShared
import Darwin
import Foundation
import Testing

/// Proves ``SecureCacheDirectory/withExclusiveLock(_:)`` provides genuine
/// mutual exclusion *across independent instances* pointed at the same
/// cache directory — the one guarantee plain Swift actor isolation cannot
/// offer, since two separately constructed `AssetDiskCache`/
/// `SecureCacheDirectory` instances (as two app scenes, or two processes,
/// would each construct) are two entirely independent actors/objects with
/// no shared in-process state to serialize against each other.
///
/// This test does not spawn a second OS process (this package has no
/// second executable target to spawn), but `flock(2)`'s mutual exclusion
/// is associated with the *open file description*, not the calling
/// process — so two independent instances contending for the same lock
/// file from two independent `Task`s in this one process already
/// exercises the exact mechanism a second real process would rely on;
/// only "is it literally two OS processes" is untested, and `flock`
/// working across processes at all is a well-established OS guarantee
/// this package does not need to reprove.
@Suite("SecureCacheDirectory cross-instance locking")
struct SecureCacheDirectoryLockingTests {
    private func withScratchDirectory(
        _ body: (_ directory: URL) async throws -> Void
    ) async throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("LockingScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    /// A small `os_unfair_lock`-guarded holder counter, deliberately *not*
    /// a Swift actor: this must be observable from two plain
    /// `Task.detached` bodies each blocked inside a *synchronous*
    /// `withExclusiveLock` call, so it cannot itself require an `await` to
    /// touch.
    private final class OverlapTracker: @unchecked Sendable {
        private var unfairLock = os_unfair_lock()
        private var currentHolders = 0
        private(set) var maxObservedConcurrentHolders = 0
        private(set) var totalEntries = 0

        func enter() {
            os_unfair_lock_lock(&unfairLock)
            currentHolders += 1
            totalEntries += 1
            maxObservedConcurrentHolders = max(maxObservedConcurrentHolders, currentHolders)
            os_unfair_lock_unlock(&unfairLock)
        }

        func exit() {
            os_unfair_lock_lock(&unfairLock)
            currentHolders -= 1
            os_unfair_lock_unlock(&unfairLock)
        }
    }

    @Test(
        """
        Two independent SecureCacheDirectory instances opened over the same directory never \
        run withExclusiveLock's body concurrently, even though each instance has its own \
        actor-independent state and its own separately opened root/lock file descriptors
        """
    )
    func withExclusiveLockSerializesAcrossIndependentInstances() async throws {
        try await withScratchDirectory { directory in
            let first = try SecureCacheDirectory(directory: directory, fileManager: .default)
            let second = try SecureCacheDirectory(directory: directory, fileManager: .default)
            let tracker = OverlapTracker()

            // Each side's critical section sleeps well past the other
            // side's own attempt to acquire the lock, so any failure to
            // serialize would reliably manifest as an observed overlap
            // (`maxObservedConcurrentHolders > 1`) rather than merely
            // being a low-probability, flaky miss.
            let firstTask = Task.detached {
                try first.withExclusiveLock {
                    tracker.enter()
                    Thread.sleep(forTimeInterval: 0.1)
                    tracker.exit()
                }
            }
            // A short, deterministic head start so `first` reliably wins
            // the initial acquisition without needing a fragile explicit
            // handshake between the two tasks.
            try await Task.sleep(nanoseconds: 20_000_000)
            let secondTask = Task.detached {
                try second.withExclusiveLock {
                    tracker.enter()
                    Thread.sleep(forTimeInterval: 0.1)
                    tracker.exit()
                }
            }

            try await firstTask.value
            try await secondTask.value

            #expect(tracker.totalEntries == 2)
            #expect(tracker.maxObservedConcurrentHolders == 1)
        }
    }

    @Test("withExclusiveLock always releases the lock even when its body throws")
    func withExclusiveLockReleasesOnThrow() async throws {
        try await withScratchDirectory { directory in
            let secure = try SecureCacheDirectory(directory: directory, fileManager: .default)
            struct MarkerError: Error {}

            #expect(throws: MarkerError.self) {
                try secure.withExclusiveLock {
                    throw MarkerError()
                }
            }

            // A second acquisition (even from the very same instance, let
            // alone a different one) must not hang or fail merely because
            // the previous call's body threw instead of returning
            // normally.
            var ranSecondBody = false
            try secure.withExclusiveLock {
                ranSecondBody = true
            }
            #expect(ranSecondBody)
        }
    }

    @Test("The reserved lock file itself is never treated as, or removed by, a cache entry sweep")
    func lockFileSurvivesRemoveAll() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: .production)
            let identifier = try AssetIdentifier.cardCode("01001")
            let assetKey = AssetKey(category: .card(.art, identifier))
            let candidates = AssetLocator.candidates(for: assetKey, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: assetKey, candidates: candidates)
            let payload = Data([1, 2, 3, 4])
            let entryMetadata = AssetCacheMetadata(
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
            try await cache.set(cacheKey, payload: payload, metadata: entryMetadata)
            try await cache.removeAll()

            let namesAfterClear = try FileManager.default
                .contentsOfDirectory(atPath: directory.path)
            #expect(namesAfterClear == [SecureCacheDirectory.lockFileName])

            // The lock must still be fully usable (same underlying inode
            // continuously locked/unlocked, never resurrected as a fresh,
            // no-longer-shared file) after a clear.
            var ranAfterClear = false
            try await cache.set(cacheKey, payload: payload, metadata: entryMetadata)
            let secure = try SecureCacheDirectory(directory: directory, fileManager: .default)
            try secure.withExclusiveLock {
                ranAfterClear = true
            }
            #expect(ranAfterClear)
        }
    }
}
