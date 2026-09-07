@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of this review round's finding #1:
/// cancelling the sole waiter of an already-applied fetch must never let
/// that waiter observe its own cancellation outcome before the durable
/// disk `.retiring` commit (``AssetDiskCache/beginRetraction(_:token:)``,
/// phase 1 of ``AssetCacheService/beginDurableRetractionIfApplied(_:token:)``)
/// has actually landed. A prior revision resumed the waiter's
/// continuation first and only *afterward* performed (or, in an earlier
/// revision still, merely launched without awaiting) the durable
/// retraction, leaving a window in which the cancelling caller — or any
/// other reader who joins immediately after observing that cancellation
/// — could still find `.content` live on disk.
///
/// This is deliberately narrower than
/// `AssetCacheServiceRetiringGenerationTests+DiskFallback.swift`'s own
/// use of the same `installTestOnlyPauseBeforeAcquiringRemovalLock` hook:
/// that file proves a *second, independent reader's* disk-hit fallback
/// correctly rejects a still-retracting entry while the removal is in
/// flight. This file instead proves something about the *cancelling
/// caller itself* — that its own `Task.value` cannot resolve at all
/// until phase 1 has completed — by pausing exactly at the same hook and
/// confirming, before releasing it, that (a) disk still durably reports
/// `.content` and (b) the caller's own outcome has provably not yet been
/// delivered, using an independent observer task rather than merely
/// inferring non-delivery from the absence of a race.
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
    /// `Task` being watched, whether `callerTask`'s own `.value` has
    /// already resolved -- deliberately not relying on the mere absence
    /// of a race (which a flaky, pre-fix implementation could still pass
    /// by accident) but on genuinely awaiting it from a second,
    /// concurrently-running task and recording completion the instant it
    /// happens.
    private actor CompletionObserver {
        private(set) var isDone = false

        func watch(_ callerTask: Task<CachedAsset, Error>) {
            Task {
                _ = try? await callerTask.value
                self.markDone()
            }
        }

        private func markDone() {
            isDone = true
        }
    }

    /// Every fixture this file's sole test needs mid-flight -- extracted
    /// purely to keep the test itself under this package's
    /// `function_body_length` limit.
    private struct RetirementOrderingScenario {
        let layers: ServiceLayers
        let cacheKey: AssetCacheKey
        let callerTask: Task<CachedAsset, Error>
        let publishGate: PauseGate
        let removalGate: PauseGate
        let observer: CompletionObserver
    }

    /// Seeds an abandoned entry, starts the original caller paused
    /// immediately after its own publish has landed, installs a pause
    /// immediately before the eventual retraction's disk-side removal
    /// acquires its exclusive lock, and begins independently observing
    /// the caller's own completion -- all strictly before this file's
    /// sole test cancels that caller.
    private func setUpRetirementOrderingScenario(
        root: URL
    ) async throws -> RetirementOrderingScenario {
        let limits = standardLimits()
        let key = try cardArtKey()
        let urls = candidateURLs(for: key)
        let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)
        let layers = try makeService(directory: root, limits: limits)

        let abandonedBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
        await layers.transport.enqueue(
            .success(successResult(body: abandonedBody)),
            for: urls[0]
        )

        // Pauses the shared fetch's own task body immediately after its
        // `publish(_:asset:token:)` call has already returned `.applied`
        // -- the entry has, by construction, already landed in both
        // cache layers by the time this file's test cancels the caller.
        let publishGate = PauseGate()
        await layers.service.installTestOnlyPauseAfterFetchPublishApplied {
            await publishGate.markStartedAndWaitForRelease()
        }

        // Pauses `AssetDiskCache`'s own removal path strictly before it
        // acquires its exclusive lock -- i.e. strictly before the
        // durable `.retiring` commit this file's test exists to fence.
        let removalGate = PauseGate()
        await layers.diskCache.installTestOnlyPauseBeforeAcquiringRemovalLock {
            await removalGate.markStartedAndWaitForRelease()
        }

        let callerTask = Task { try await layers.service.asset(for: key) }
        await publishGate.waitUntilStarted()
        #expect(await layers.memoryCache.get(cacheKey) != nil)

        let observer = CompletionObserver()
        await observer.watch(callerTask)

        return RetirementOrderingScenario(
            layers: layers,
            cacheKey: cacheKey,
            callerTask: callerTask,
            publishGate: publishGate,
            removalGate: removalGate,
            observer: observer
        )
    }

    /// Polls (test-only) until `observer.isDone`, or fails the test via
    /// `Issue.record` if `timeoutNanoseconds` elapses first -- matching
    /// this suite's established `waitForMemoryEntryRetracted`/
    /// `waitForDiskDispositionRetracted` polling convention.
    private func waitForObserverDone(
        _ observer: CompletionObserver,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while await observer.isDone == false {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                let timeoutMessage = "Timed out waiting for the cancelling caller's outcome "
                    + "to resolve after releasing the durable retiring commit"
                Issue.record("\(timeoutMessage)")
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @Test(
        """
        Cancelling the sole waiter of an already-applied fetch must not resolve that waiter's \
        own outcome before the durable disk `.retiring` commit has actually landed: while that \
        commit is deliberately held just before it acquires its exclusive lock, disk must still \
        report `.content` and the cancelling caller's own task must provably not yet have \
        completed; only once the commit is allowed to proceed does the caller observe \
        cancellation, and disk simultaneously stop reporting `.content`.
        """
    )
    func cancellationCannotResolveBeforeDurableRetiringCommitLands() async throws {
        try await withScratchDirectory { root in
            let scenario = try await setUpRetirementOrderingScenario(root: root)

            scenario.callerTask.cancel()
            // The shared fetch task itself remains parked at
            // `publishGate` (a plain `withCheckedContinuation`, not
            // automatically woken by cancellation); released here purely
            // so it can eventually finish and get torn down cleanly --
            // `cancelWaiter`'s own retraction below runs independently of
            // it either way, exactly as
            // `AssetCacheServiceRetiringGenerationTests+DiskFallback.swift`'s
            // own scenario already establishes.
            await scenario.publishGate.release()

            // Returns only once the retraction triggered by the
            // cancellation above has reached `AssetDiskCache`'s removal
            // path and parked immediately before its exclusive lock --
            // i.e. strictly before any durable `.retiring` write.
            await scenario.removalGate.waitUntilStarted()

            let dispositionWhilePaused = try await scenario.layers.diskCache.currentKeyDisposition(
                for: scenario.cacheKey
            )
            #expect(
                dispositionWhilePaused.kind == .content,
                """
                Disk must still durably report `.content` while the retraction's own durable \
                commit is deliberately held before it
                """
            )

            // A bounded, generous wait for scheduler jitter alone -- not
            // a race the fix depends on winning: `observer`'s watch task
            // can only ever transition to `isDone` via `callerTask.value`
            // resolving, which (per `cancelWaiter`'s own ordering) cannot
            // happen until `beginRetraction` returns -- and that call is
            // deterministically parked at `removalGate`, not merely
            // likely to still be running.
            try await Task.sleep(nanoseconds: 150_000_000)
            #expect(
                await scenario.observer.isDone == false,
                """
                The cancelling caller's own outcome must not resolve while the durable \
                `.retiring` commit is still held before its exclusive lock
                """
            )

            await scenario.removalGate.release()
            await waitForObserverDone(scenario.observer)

            await #expect(throws: CancellationError.self) {
                _ = try await scenario.callerTask.value
            }

            let dispositionAfterRelease = try await scenario.layers.diskCache.currentKeyDisposition(
                for: scenario.cacheKey
            )
            #expect(
                dispositionAfterRelease.kind != .content,
                """
                Once the durable retiring commit is allowed to proceed, disk must stop \
                reporting `.content` for this exact abandoned entry
                """
            )
        }
    }
}
