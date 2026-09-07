@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of a review finding against
/// `AssetCacheService+IssuanceDecisionLock.swift`: a caller cancelled
/// while still queued for a key's issuance decision lock
/// (``AssetCacheService/acquireIssuanceDecisionLock(for:)``) must be
/// resumed with `CancellationError` the moment its own cancellation is
/// observed, never only once it eventually reaches the front of the
/// queue and is silently handed a lock it can no longer legitimately
/// use. A prior revision awaited a plain, non-cancellation-aware
/// `CheckedContinuation<Void, Never>`: a cancelled queued waiter simply
/// sat there until ``AssetCacheService/releaseIssuanceDecisionLock(for:)``
/// eventually reached it in FIFO order, at which point it still resumed
/// normally and went on to inspect ``AssetCacheService/inFlight`` and
/// potentially reserve fresh disk authority despite having already been
/// cancelled — defeating the lock's own purpose and, worse, doing
/// meaningful cache-mutating work on behalf of an operation nobody is
/// still waiting on.
extension AssetCacheServiceTests {
    /// Identical in shape to this suite's sibling race-test `PauseGate`s
    /// (not shared across files, by this suite's established
    /// convention).
    private actor PauseGate {
        private var hasStarted = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var isReleased = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func waitUntilStarted() async {
            if hasStarted {
                return
            }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func markStartedAndWaitForRelease() async {
            hasStarted = true
            let waiters = startWaiters
            startWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
            if isReleased {
                return
            }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func release() {
            isReleased = true
            let waiters = releaseWaiters
            releaseWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    /// Records, in a form independently observable from outside the
    /// `Task` being watched, whether `watchedTask`'s own `.value` has
    /// already resolved — deliberately not relying on the mere absence
    /// of a race (which a flaky, pre-fix implementation could still pass
    /// by accident) but on genuinely awaiting it from a second,
    /// concurrently-running task and recording completion the instant it
    /// happens.
    private actor CompletionObserver {
        private(set) var isDone = false

        func watch(_ watchedTask: Task<CachedAsset, Error>) {
            Task {
                _ = try? await watchedTask.value
                self.markDone()
            }
        }

        private func markDone() {
            isDone = true
        }
    }

    /// Polls (test-only) until `observer.isDone`, or fails the test via
    /// `Issue.record` if `timeoutNanoseconds` elapses first — matching
    /// this suite's established polling convention.
    private func waitForObserverDone(
        _ observer: CompletionObserver,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while await observer.isDone == false {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                Issue.record("Timed out waiting for the cancelled queued waiter to resolve")
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Polls (test-only) until `key`'s issuance decision queue reaches
    /// `expectedCount`, or fails the test via `Issue.record` if
    /// `timeoutNanoseconds` elapses first — proving the second caller
    /// below has genuinely become queued (rather than merely being
    /// likely to be) before this test acts on it.
    private func waitForIssuanceDecisionWaiterCount(
        _ service: AssetCacheService,
        cacheKey: AssetCacheKey,
        expectedCount: Int,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while await service.issuanceDecisionWaiterCount(for: cacheKey) != expectedCount {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                let message = "Timed out waiting for \(expectedCount) issuance decision " +
                    "waiter(s) to be queued"
                Issue.record("\(message)")
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @Test(
        """
        A caller cancelled while still queued behind another caller's held issuance decision \
        lock for the identical key must resolve to `CancellationError` immediately -- strictly \
        before the lock holder ever releases it -- rather than only discovering its own \
        cancellation once its turn eventually comes and it is handed a lock it can no longer \
        legitimately use; the lock holder's own operation must complete normally afterward, \
        proving the cancelled waiter's removal never corrupts the queue for anyone still \
        legitimately waiting.
        """
    )
    func cancelledQueuedIssuanceWaiterResolvesBeforeLockReleases() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let layers = try makeService(directory: root, limits: limits)

            let abandonedBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            let response = successResult(body: abandonedBody)
            await layers.transport.enqueue(.success(response), for: urls[0])

            // Pauses the first caller for `key` immediately after it
            // acquires the issuance decision lock -- before it ever
            // inspects `inFlight` or reserves any disk authority -- so a
            // second, concurrent caller for the identical key is
            // guaranteed to still find the lock held and must queue
            // behind it.
            let lockHolderGate = PauseGate()
            await layers.service.installTestOnlyPauseHoldingIssuanceLock {
                await lockHolderGate.markStartedAndWaitForRelease()
            }

            let firstCallerTask = Task { try await layers.service.asset(for: key) }
            await lockHolderGate.waitUntilStarted()

            let secondCallerTask = Task { try await layers.service.asset(for: key) }
            await waitForIssuanceDecisionWaiterCount(
                layers.service,
                cacheKey: cacheKey,
                expectedCount: 1
            )

            let secondCallerObserver = CompletionObserver()
            await secondCallerObserver.watch(secondCallerTask)
            secondCallerTask.cancel()

            // Returns only once the cancelled queued waiter's own
            // continuation has genuinely resumed -- while the first
            // caller's lock is still deliberately held (`lockHolderGate`
            // has not been released yet below), proving this resolution
            // came from the cancellation-handling path in
            // `acquireIssuanceDecisionLock(for:)`, never from an
            // ordinary FIFO hand-off this test never triggers.
            await waitForObserverDone(secondCallerObserver)
            await #expect(throws: CancellationError.self) {
                _ = try await secondCallerTask.value
            }

            // The cancelled waiter must be fully gone from the queue --
            // never left behind as a phantom entry that could still be
            // handed the lock later, and never having touched `inFlight`
            // at all.
            #expect(await layers.service.issuanceDecisionWaiterCount(for: cacheKey) == 0)
            #expect(try await layers.service.inFlightWaiterCount(for: key) == 0)

            // Only now released: the first caller's own operation, which
            // was never cancelled, must still complete successfully --
            // proving the second caller's cancellation never corrupted
            // this key's lock/queue state for the legitimate holder.
            await lockHolderGate.release()
            let firstCallerAsset = try await firstCallerTask.value
            #expect(firstCallerAsset.metadata.contentType == "image/avif")
        }
    }
}
