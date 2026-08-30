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
                try await first.withExclusiveLock {
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
                try await second.withExclusiveLock {
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

    @Test(
        """
        Cancelling a Task that is waiting to acquire a lock held by another instance \
        releases its wait promptly (bounded by the poll interval, not by however long the \
        holder keeps the lock), and never resumes as though the lock had been acquired
        """
    )
    func acquireExclusiveLockIsCancellationAware() async throws {
        try await withScratchDirectory { directory in
            let holderInstance = try SecureCacheDirectory(
                directory: directory,
                fileManager: .default
            )
            let waiterInstance = try SecureCacheDirectory(
                directory: directory,
                fileManager: .default
            )

            let holderLockFD = try await holderInstance.acquireExclusiveLock()
            // Held for far longer than any reasonable poll interval, so a
            // waiter that actually blocked until acquisition (rather than
            // observing its own cancellation) would only resume at or
            // after this deadline -- making a resume well before it an
            // unambiguous proof of cancellation, not a lucky race.
            let holdDuration: UInt64 = 2_000_000_000

            let waiterTask = Task {
                try await waiterInstance.acquireExclusiveLock()
            }
            // A short, deterministic head start so `waiterTask` is
            // reliably already inside its poll loop, genuinely contending
            // for the held lock, before being cancelled.
            try await Task.sleep(nanoseconds: 50_000_000)
            let cancelStart = DispatchTime.now()
            waiterTask.cancel()

            var caughtCancellation = false
            do {
                _ = try await waiterTask.value
            } catch is CancellationError {
                caughtCancellation = true
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
            }
            let elapsedSinceCancel = DispatchTime.now().uptimeNanoseconds
                - cancelStart.uptimeNanoseconds

            #expect(caughtCancellation)
            #expect(
                elapsedSinceCancel < holdDuration,
                "A cancelled waiter must release well before the holder's own hold duration"
            )

            holderInstance.releaseExclusiveLock(holderLockFD)

            // The lock itself must be left in a clean, reacquirable state
            // -- the cancelled waiter must not have left any stray hold,
            // partial state, or leaked descriptor behind.
            let freshLockFD = try await waiterInstance.acquireExclusiveLock()
            waiterInstance.releaseExclusiveLock(freshLockFD)
        }
    }

    @Test("withExclusiveLock always releases the lock even when its body throws")
    func withExclusiveLockReleasesOnThrow() async throws {
        try await withScratchDirectory { directory in
            let secure = try SecureCacheDirectory(directory: directory, fileManager: .default)
            struct MarkerError: Error {}

            await #expect(throws: MarkerError.self) {
                try await secure.withExclusiveLock {
                    throw MarkerError()
                }
            }

            // A second acquisition (even from the very same instance, let
            // alone a different one) must not hang or fail merely because
            // the previous call's body threw instead of returning
            // normally.
            var ranSecondBody = false
            try await secure.withExclusiveLock {
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
            // Only the reserved lock file and the durable access-sequence
            // counter file are expected to survive a `removeAll()` --
            // every actual cache entry must be gone. This cache no longer
            // persists a durable, cross-process clear-epoch marker (see
            // ``AssetDiskCache``'s own doc comment): a fresh disk-only hit
            // is always required to pass an online conditional
            // revalidation before being trusted, which makes a durable
            // clear-epoch marker unnecessary for correctness. The
            // access-sequence counter, unlike a clear-epoch marker, must
            // survive: it is what keeps LRU ordering globally monotonic
            // across a clear, not a correctness-sensitive authority token.
            #expect(
                Set(namesAfterClear) == [
                    SecureCacheDirectory.lockFileName,
                    SecureCacheDirectory.accessSequenceFileName,
                ]
            )

            // The lock must still be fully usable (same underlying inode
            // continuously locked/unlocked, never resurrected as a fresh,
            // no-longer-shared file) after a clear.
            var ranAfterClear = false
            try await cache.set(cacheKey, payload: payload, metadata: entryMetadata)
            let secure = try SecureCacheDirectory(directory: directory, fileManager: .default)
            try await secure.withExclusiveLock {
                ranAfterClear = true
            }
            #expect(ranAfterClear)
        }
    }

    @Test(
        "withExclusiveLock refuses to lock a non-regular-file planted at the lock file's name"
    )
    func withExclusiveLockRefusesNonRegularLockFile() async throws {
        try await withScratchDirectory { directory in
            // Construct once to create the verified root directory itself,
            // then close it again before planting the FIFO: this type
            // never re-resolves the lock file's name outside
            // `withExclusiveLock`, so nothing else needs to be holding it
            // open at this point.
            _ = try SecureCacheDirectory(directory: directory, fileManager: .default)

            let lockPath = directory.appendingPathComponent(SecureCacheDirectory.lockFileName)
            #expect(mkfifo(lockPath.path, 0o600) == 0)

            let secure = try SecureCacheDirectory(directory: directory, fileManager: .default)
            await #expect(throws: AssetError.self) {
                try await secure.withExclusiveLock {
                    Issue.record("body must never run against a non-regular-file lock name")
                }
            }
        }
    }

    @Test(
        """
        withExclusiveLock refuses to lock an external hardlink planted at the lock file's exact \
        name, even though it is a regular file `flock` itself would happily lock
        """
    )
    func withExclusiveLockRefusesHardlinkedLockFile() async throws {
        try await withScratchDirectory { directory in
            _ = try SecureCacheDirectory(directory: directory, fileManager: .default)

            let lockPath = directory.appendingPathComponent(SecureCacheDirectory.lockFileName)
            // Remove the real (freshly created, single-link) lock file
            // first, then hardlink in a *different* regular file: `flock`
            // itself has no objection to locking an ordinary regular
            // file, no matter its link count or origin, so this is
            // exactly the case a bare "did `openat`/`flock` succeed?"
            // check cannot catch, and only an explicit link-count/type
            // verification (mirroring every other entry this cache reads
            // through ``SecureCacheDirectory/requireVerifiedRegularFile(descriptor:name:)``)
            // can.
            _ = try? FileManager.default.removeItem(at: lockPath)
            let externalFile = directory.deletingLastPathComponent()
                .appendingPathComponent("external-\(UUID().uuidString)")
            try Data("not this cache's own lock file".utf8).write(to: externalFile)
            defer { try? FileManager.default.removeItem(at: externalFile) }
            #expect(link(externalFile.path, lockPath.path) == 0)

            let secure = try SecureCacheDirectory(directory: directory, fileManager: .default)
            await #expect(throws: AssetError.self) {
                try await secure.withExclusiveLock {
                    Issue.record("body must never run against a hardlinked lock file")
                }
            }
        }
    }
}
