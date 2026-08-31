@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of this review round's finding #3:
/// ``AssetDiskCache/removeIfApplied(_:token:)`` must propagate a genuine
/// disk I/O failure while retracting an already-published entry as a
/// typed error -- never silently swallow it via `try?` and report success
/// regardless of whether the underlying content actually stopped being
/// servable. ``AssetCacheService/retractIfApplied(_:token:)`` (the sole
/// caller, used by both ``AssetCacheService/cancelWaiter(_:fetchID:waiterID:)``
/// and ``AssetCacheService/cancelRevalidationWaiter(_:fetchID:waiterID:)``)
/// must record that failure into
/// ``AssetCacheService/lastDiskPersistenceFailure`` for auditing and mark
/// the key in ``AssetCacheService/tombstonedKeys`` so a later disk-hit
/// lookup fails closed against whatever inconsistent on-disk state the
/// failed removal may have left behind, rather than trusting a "removal
/// succeeded" outcome that never actually happened.
///
/// Split from `AssetCacheServiceTests.swift`/`AssetCacheServiceRetirementFenceTests.swift`
/// (reusing their `cardArtKey`/`candidateURLs`/`successResult` and
/// `AssetCacheServicePersistenceTests`'s `ServiceLayers`/`makeService`
/// helpers) purely for `file_length`.
extension AssetCacheServiceTests {
    /// Identical in shape to this suite's sibling race-test `PauseGate`s.
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

    /// Polls (test-only; not a production concurrency pattern) until
    /// `memoryCache` no longer holds an entry for `cacheKey`, or fails
    /// the test via `Issue.record` if `timeoutNanoseconds` elapses first
    /// — identical in shape to `AssetCacheServiceRetirementFenceTests.swift`'s
    /// own private helper of the same name (not shared across files, by
    /// this suite's established convention).
    private func waitForMemoryEntryRetracted(
        _ memoryCache: AssetMemoryCache,
        cacheKey: AssetCacheKey,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while await memoryCache.get(cacheKey) != nil {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                Issue.record(
                    "Timed out waiting for the abandoned entry to be retracted from memory"
                )
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @Test(
        """
        A retraction whose disk-side metadata removal genuinely fails records a typed \
        persistence failure and tombstones the key, rather than silently reporting success
        """
    )
    func retractionDiskRemovalFailureIsAuditedAndTombstonesKey() async throws {
        try await withScratchDirectory { root in
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

            let gate = PauseGate()
            await layers.service.installTestOnlyPauseAfterFetchPublishApplied {
                await gate.markStartedAndWaitForRelease()
            }

            let callerTask = Task { try await layers.service.asset(for: key) }

            // Returns only once `publish(_:asset:token:)` has already
            // returned `.applied` for this exact fetch -- the entry has,
            // by construction, already landed in both cache layers by
            // this point.
            await gate.waitUntilStarted()
            #expect(await layers.memoryCache.get(cacheKey) != nil)

            // Fail exactly this key's metadata-pointer removal -- the
            // one disk write `removeIfApplied(_:token:)` performs to
            // retract the publication -- installed *before* cancellation
            // so it is unconditionally active by the time the
            // cancellation-triggered retraction (which can run to
            // completion concurrently with the still-paused fetch task,
            // not only after `gate.release()`) attempts that removal.
            let metadataName = await layers.diskCache.metadataFilename(for: cacheKey)
            await layers.diskCache.directoryAccess.installFaultInjection(
                failRemoveSuffixes: [metadataName]
            )

            callerTask.cancel()

            // Poll until the retraction's own disk attempt has definitely
            // run and recorded its outcome (whether it failed, as this
            // test expects, or -- pre-fix -- silently swallowed the
            // error) before inspecting `lastDiskPersistenceFailure`,
            // rather than racing an unawaited retraction task.
            await waitForMemoryEntryRetracted(layers.memoryCache, cacheKey: cacheKey)

            await gate.release()
            await #expect(throws: CancellationError.self) {
                _ = try await callerTask.value
            }

            // The fix under test: the genuine disk I/O failure must be
            // captured for auditing, not silently folded into "removal
            // already a no-op tombstone" or otherwise swallowed.
            let failure = await layers.service.lastDiskPersistenceFailure
            let failureMessage = "A genuine disk removal failure during retraction must be " +
                "recorded, not silently swallowed"
            #expect(failure != nil, "\(failureMessage)")
            if case .cachePersistenceFailed = failure {
                // Expected typed classification.
            } else {
                Issue.record("Expected .cachePersistenceFailed, got \(String(describing: failure))")
            }

            // Memory-side retraction is independent of the disk failure
            // and must still have happened -- this is a best-effort,
            // never-blocks-on-the-other-layer removal.
            let memoryAfter = await layers.memoryCache.get(cacheKey)
            #expect(
                memoryAfter == nil,
                "Memory retraction must proceed even though the disk-side removal failed"
            )

            // The key must now be fail-closed for any later disk-hit
            // lookup: whatever inconsistent state the failed removal left
            // behind on disk must never be trusted as a valid hit again.
            #expect(await layers.service.tombstonedKeys.contains(cacheKey))
        }
    }
}
