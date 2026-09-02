@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of the final cumulative review's finding
/// #3: retirement of a coalesced fetch/revalidation's token, when its
/// sole (last) waiter cancels, must not merely block *future* mutations
/// under that token — it must also retract any mutation the shared task's
/// own body already committed *before* this exact cancellation reached
/// the actor. Without that retraction, a fetch that happened to finish
/// publishing successfully in the narrow window between "cancellation was
/// requested" and "the cancellation's own actor hop actually ran" would
/// leave a fully valid, readable cache entry behind — served to any
/// later caller as an ordinary authoritative hit — even though the sole
/// caller who ever asked for that work walked away and observed nothing
/// but `CancellationError`. Per this subsystem's own cancellation
/// contract ("when the last waiter leaves, cancellation may stop the
/// fetch and must leave no partial cache entry"), an entry produced by
/// abandoned work must never survive that abandonment merely because the
/// underlying network round trip happened to race the cancellation and
/// win.
///
/// Split from `AssetCacheServiceTests.swift` purely for `file_length`,
/// reusing its `cardArtKey`/`candidateURLs`/`successResult` helpers and
/// `AssetCacheServicePersistenceTests`'s `ServiceLayers`/`makeService`
/// helpers for direct access to the underlying `memoryCache`/`diskCache`
/// actors (needed to observe the abandoned entry's presence/absence
/// directly, independent of `AssetCacheService`'s own authority-gated
/// read paths under test).
extension AssetCacheServiceTests {
    /// Identical in shape to this file's sibling race-test `PauseGate`s
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

    /// Polls (test-only; not a production concurrency pattern) until
    /// `memoryCache` no longer holds an entry for `cacheKey`, or fails the
    /// test via `Issue.record` if `timeoutNanoseconds` elapses first —
    /// mirroring `FakeAssetTransport.waitForCallCount(_:for:timeoutNanoseconds:)`'s
    /// own "poll with a generous, scheduling-tolerant deadline, but never
    /// silently proceed past a deadline that was actually reached" idiom.
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
        A fetch that finishes publishing successfully in the narrow window between its sole \
        waiter cancelling and that cancellation reaching the actor has its already-applied \
        mutation retracted from both cache layers, rather than left servable to a later caller
        """
    )
    func lastWaiterCancellationRetractsAnAlreadyAppliedFetchPublish() async throws {
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
            // returned `.applied` for this exact fetch: the abandoned
            // entry has, by construction, already landed in both cache
            // layers by this point -- no separate poll needed to confirm
            // it, unlike the retraction below (whose whole point is that
            // it happens concurrently with, not before, this pause).
            await gate.waitUntilStarted()
            #expect(await layers.memoryCache.get(cacheKey) != nil)

            callerTask.cancel()

            // The fix under test: even though the underlying task is
            // still paused (deliberately) rather than having "finished"
            // in the Task<> sense, `cancelWaiter`'s retraction runs
            // concurrently against this same actor and must remove the
            // already-committed entry from both layers before this
            // waiter's cancellation is considered fully resolved.
            await waitForMemoryEntryRetracted(layers.memoryCache, cacheKey: cacheKey)
            let diskEntryAfterCancel = try await layers.diskCache.get(cacheKey)
            #expect(
                diskEntryAfterCancel == nil,
                "The abandoned fetch's disk write must also be retracted, not only memory's"
            )

            await gate.release()
            await #expect(throws: CancellationError.self) {
                _ = try await callerTask.value
            }

            // A completely fresh request for the same key must perform a
            // genuine new fetch -- proving the retraction actually
            // removed the abandoned entry rather than merely hiding it
            // behind some other bookkeeping check that a later request
            // might not exercise.
            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 6, height: 6)
            await layers.transport.enqueue(.success(successResult(body: freshBody)), for: urls[0])
            let resolved = try await layers.service.asset(for: key)
            #expect(resolved.payload == freshBody)
            #expect(await layers.transport.callCount(for: urls[0]) == 2)
        }
    }

    @Test(
        """
        A revalidation that finishes publishing a fresh 200 response successfully in the \
        narrow window between its sole waiter cancelling and that cancellation reaching the \
        actor has its already-applied mutation retracted from both cache layers
        """
    )
    func lastWaiterCancellationRetractsAnAlreadyAppliedRevalidationPublish() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let layers = try makeService(directory: root, limits: limits)

            // Seed a real cache entry (memory + disk) with an `ETag`, so
            // it is eligible for conditional revalidation, before ever
            // installing the pause hook below.
            let seedBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            await layers.transport.enqueue(
                .success(successResult(body: seedBody, etag: "\"v1\"")),
                for: urls[0]
            )
            let seeded = try await layers.service.asset(for: key)
            #expect(seeded.payload == seedBody)

            let abandonedBody = AssetImageFixtureBuilder.validAVIF(width: 5, height: 5)
            await layers.transport.enqueue(
                .success(successResult(body: abandonedBody, etag: "\"v2\"")),
                for: urls[0]
            )

            let gate = PauseGate()
            await layers.service.installTestOnlyPauseAfterFetchPublishApplied {
                await gate.markStartedAndWaitForRelease()
            }

            let callerTask = Task { try await layers.service.revalidate(for: key) }

            // Returns only once the fresh 200's `publish(_:asset:token:)`
            // call has already returned `.applied`: `abandonedBody` has,
            // by construction, already overwritten `seedBody` in both
            // cache layers by this point.
            await gate.waitUntilStarted()
            let appliedDuringPause = await layers.memoryCache.get(cacheKey)
            #expect(appliedDuringPause?.payload == abandonedBody)

            callerTask.cancel()

            // The fix under test: the already-committed `abandonedBody`
            // mutation must be retracted -- reverting this key to
            // genuinely having no trustworthy cache entry left (not
            // silently reverting to the older `seedBody`, which this
            // revalidation's own token no longer has any claim to either
            // -- see ``AssetMemoryCache/removeIfApplied(_:token:)``: it
            // retracts only the exact entry applied under this exact
            // token, never restoring whatever preceded it).
            await waitForMemoryEntryRetracted(layers.memoryCache, cacheKey: cacheKey)
            let diskEntryAfterCancel = try await layers.diskCache.get(cacheKey)
            #expect(diskEntryAfterCancel == nil)

            await gate.release()
            await #expect(throws: CancellationError.self) {
                _ = try await callerTask.value
            }

            // A completely fresh request for the same key must perform a
            // genuine new (unconditional) fetch: there is no longer any
            // trustworthy cached entry (old or new) left for it to
            // conditionally revalidate against.
            let finalBody = AssetImageFixtureBuilder.validAVIF(width: 7, height: 7)
            await layers.transport.enqueue(.success(successResult(body: finalBody)), for: urls[0])
            let resolved = try await layers.service.asset(for: key)
            #expect(resolved.payload == finalBody)
        }
    }
}
