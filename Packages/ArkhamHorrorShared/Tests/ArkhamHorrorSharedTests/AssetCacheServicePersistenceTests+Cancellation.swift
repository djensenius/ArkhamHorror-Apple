@testable import ArkhamHorrorShared
import Foundation
import Testing

/// A caller-cancellation regression for ``AssetCacheService``'s disk-write
/// persistence bookkeeping. Split out of `AssetCacheServicePersistenceTests.swift`
/// (reusing its helpers, exactly like `AssetCacheServiceRevalidationTests.swift`
/// reuses `AssetCacheServiceTests.swift`'s) purely to stay under SwiftLint's
/// `file_length`.
extension AssetCacheServiceTests {
    @Test(
        """
        A caller's task being cancelled while `publish`'s own disk write is suspended, \
        queued behind another in-process caller genuinely holding the cross-process lock, \
        must never be recorded as a disk-persistence failure -- it is a cancelled attempt, \
        not an attempted-and-failed write, and incorrectly recording it would wrongly block \
        the tombstone-clearing logic gated on it
        """
    )
    func cancellationWhileQueuedForDiskWriteLockIsNotRecordedAsPersistenceFailure() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let layers = makeService(diskCache: diskCache, limits: limits)

            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await layers.transport.enqueue(.success(successResult()), for: urls[0])

            let secure = await diskCache.directoryAccess
            let heldLock = LockFDBox()
            let queuedForWrite = AsyncStream<Void>.makeStream()

            // `asset(for:)`'s own disk-miss check (`diskCache.get`), every
            // durable-clear-epoch read `fetchAndValidate`/`validateAndPublish`/
            // `publish` each perform against this exact same cross-process
            // lock before ever reaching `publish`'s own `diskCache.set`
            // call, and `publish`'s own pre-memory-write authority check
            // all also acquire this same lock -- so holding it from the
            // very start of this test, or anchoring on any of those
            // earlier acquisitions, would make one of *them* -- rather
            // than the write this test actually targets -- the one seen
            // queuing. Anchoring on `diskCache`'s own dedicated
            // ``AssetDiskCache/testOnlyPauseBeforeAcquiringWriteLock``
            // hook instead sidesteps that entirely: it fires only
            // immediately before `set(_:payload:metadata:token:)`'s own
            // lock acquisition, strictly after every one of those earlier
            // reads has already completed (each independently, and
            // uncontended, since this test has not yet taken the lock at
            // all by that point) -- so acquiring the lock for this test
            // *here* guarantees the very next acquisition attempt is
            // exactly that write, regardless of how many authority
            // re-checks now precede it.
            await diskCache.installTestOnlyPauseBeforeAcquiringWriteLock {
                heldLock.descriptor = try? await secure.acquireExclusiveLock()
                secure.lockCoordinator.onWaiterPositionEstablished = {
                    queuedForWrite.continuation.yield()
                }
            }

            // Fired once `recordDiskPersistenceResult` has finished
            // updating `lastDiskPersistenceFailure` -- proving that exact
            // actor-isolated bookkeeping has completed, rather than
            // merely that `task.value` below has returned. Those two are
            // *not* the same moment: a cancelled waiter's own
            // continuation resumes as soon as `cancelWaiter` runs (see
            // its doc comment), decoupled from whenever the underlying
            // shared fetch's `diskCache.set` call itself actually
            // finishes reacting to its own cancellation -- checking
            // `lastDiskPersistenceFailure` immediately after `task.value`
            // alone would race that.
            let resultRecorded = AsyncStream<Void>.makeStream()
            await layers.service.installTestOnlyDiskPersistenceRecordedHook {
                resultRecorded.continuation.yield()
            }
            var resultRecordedIterator = resultRecorded.stream.makeAsyncIterator()

            let task = Task<CachedAsset, Error> {
                try await layers.service.asset(for: key)
            }
            var queuedIterator = queuedForWrite.stream.makeAsyncIterator()
            _ = await queuedIterator.next()

            // Cancelling this sole waiter is itself the *last* waiter for
            // this key's shared in-flight fetch, so the underlying fetch
            // task -- including its own suspended `diskCache.set` call,
            // still genuinely queued behind this test's own held lock,
            // never released below -- is cancelled too (see
            // `cancelWaiter`'s doc comment): its lock wait resumes with a
            // real `CancellationError` from the coordinator, exactly the
            // suspension window a prior review found could otherwise be
            // mistaken for a persistence failure. `asset(for:)` itself
            // deliberately surfaces `CancellationError` to this cancelled
            // caller regardless of whether the shared work it was joining
            // happened to still land -- that outcome is already covered by
            // `AssetCacheServiceCoalescingTests`; what this test proves is
            // only that the disk write's own cancellation is never
            // recorded as a failure.
            task.cancel()

            _ = await resultRecordedIterator.next()
            let failure = await layers.service.lastDiskPersistenceFailure
            if let descriptor = heldLock.descriptor {
                secure.releaseExclusiveLock(descriptor)
            }

            await #expect(throws: CancellationError.self) {
                try await task.value
            }

            #expect(
                failure == nil,
                """
                Cancellation while queued behind another caller's lock hold must never be \
                recorded as a disk-persistence failure
                """
            )
        }
    }

    /// A tiny mutable box for a lock file descriptor, purely so
    /// ``cancellationWhileQueuedForDiskWriteLockIsNotRecordedAsPersistenceFailure()``
    /// can assign into it from inside an escaping, non-actor-isolated
    /// test hook closure without capturing a plain `var` across a
    /// concurrency boundary.
    final class LockFDBox: @unchecked Sendable {
        var descriptor: Int32?
    }
}
