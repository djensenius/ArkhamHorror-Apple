@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of the narrowest form of this subsystem's
/// most persistently-flagged cancellation defect: a concurrent reader
/// that already captured a soon-to-be-retracted memory entry -- via
/// ``AssetMemoryCache/get(_:)``, paused (by this test) immediately after
/// capturing it but before returning it to its caller -- must still have
/// its own subsequent authority check reject that entry, even once the
/// retraction that dooms it has *already fully completed* by the time
/// this reader's own check finally runs.
///
/// This is deliberately a different (and strictly narrower) race than
/// `AssetCacheServiceRetirementFenceTests.swift` already covers: that
/// file proves an abandoned mutation's own already-applied entry is
/// eventually retracted at all (nothing durable survives once the
/// retraction itself has run to completion). It does not, by itself,
/// prove anything about a *second*, independent reader who -- through
/// entirely ordinary actor-hop timing, not any fault of its own -- managed
/// to read the doomed entry from `AssetMemoryCache` before that retraction
/// removed it, and whose own suspicion-free "is this still current?"
/// check might run at any point relative to the retraction: before it
/// starts, while it is in flight, or (the specific case this file proves)
/// strictly after it has already finished. A first design considered for
/// ``AssetCacheService/retiringGenerations`` cleared each key's marker the
/// instant its own retraction's removal completed -- which this exact
/// scenario would have broken, since there is no way to bound how long a
/// reader who already captured the entry beforehand might remain
/// suspended before performing its own check. The shipped design never
/// clears an entry from `retiringGenerations` individually at all (a
/// retired ticket can never legitimately become valid again for its key
/// within its epoch), which is what this file's tests hold to account.
extension AssetCacheServiceTests {
    /// Identical in shape to `AssetCacheServiceRetirementFenceTests.swift`'s
    /// own `PauseGate` (not shared across files, by this suite's
    /// established convention).
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

    /// Polls until `memoryCache` no longer holds an entry for `cacheKey`
    /// -- this file's own copy of
    /// `AssetCacheServiceRetirementFenceTests.swift`'s identical helper,
    /// kept separate purely because that file's version is `private` to
    /// its own `extension AssetCacheServiceTests` declaration.
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

    /// Starts `operation` as a caller task paused immediately after its
    /// own fetch/revalidation has already published to both cache
    /// layers, returning once that pause point is reached. Shared by
    /// this file's tests purely to keep each test's own body under this
    /// package's `function_body_length` limit.
    private func startCallerPausedAfterPublish(
        service: AssetCacheService,
        operation: @escaping @Sendable () async throws -> CachedAsset
    ) async -> (task: Task<CachedAsset, Error>, gate: PauseGate) {
        let gate = PauseGate()
        await service.installTestOnlyPauseAfterFetchPublishApplied {
            await gate.markStartedAndWaitForRelease()
        }
        let task = Task { try await operation() }
        await gate.waitUntilStarted()
        return (task, gate)
    }

    /// Starts `operation` as a second, independent reader paused
    /// immediately after its own ``AssetMemoryCache/get(_:)`` call has
    /// already captured a (soon-to-be-stale) entry, but before that
    /// entry is returned back for the reader's own authority check --
    /// then neutralizes the pause hook for every subsequent call, since
    /// the reader's own in-flight invocation has already captured the
    /// closure it is currently suspended inside. Shared by this file's
    /// tests purely to keep each test's own body under this package's
    /// `function_body_length` limit.
    private func startReaderCapturingStaleMemoryHit(
        memoryCache: AssetMemoryCache,
        operation: @escaping @Sendable () async throws -> CachedAsset
    ) async -> (task: Task<CachedAsset, Error>, gate: PauseGate) {
        let gate = PauseGate()
        await memoryCache.installTestOnlyPauseBeforeReturningHit {
            await gate.markStartedAndWaitForRelease()
        }
        let task = Task { try await operation() }
        await gate.waitUntilStarted()
        await memoryCache.installTestOnlyPauseBeforeReturningHit {}
        return (task, gate)
    }

    @Test(
        """
        A reader who captured a memory entry moments before its sole waiter's cancellation \
        retracted it -- and whose own authority check does not run until strictly after that \
        retraction has already fully completed -- must still have that stale entry rejected: \
        retiringGenerations is never cleared once its retraction completes, precisely so this \
        unbounded-delay reader can never slip through the gap a "clear on completion" design \
        would have left open
        """
    )
    func readerDelayedPastCompletedRetractionStillRejectsStaleEntry() async throws {
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

            let (callerTask, publishGate) = await startCallerPausedAfterPublish(
                service: layers.service
            ) {
                try await layers.service.asset(for: key)
            }

            // Returns only once the fetch's own publish has already
            // landed in both cache layers, and the fetch's own task is
            // now deliberately paused before ever returning to its
            // (sole) waiter.
            #expect(await layers.memoryCache.get(cacheKey) != nil)

            // A second, independent reader now begins its own lookup for
            // the exact same key. Its own `memoryCache.get` call is
            // paused (by this test) immediately after it has already
            // captured `abandonedBody`'s entry, but before that entry is
            // returned back to `asset(for:)` for its own authority
            // check.
            let (readerTask, readerGate) = await startReaderCapturingStaleMemoryHit(
                memoryCache: layers.memoryCache
            ) {
                try await layers.service.asset(for: key)
            }

            // Only now does the original caller cancel -- the sole
            // waiter of the still-paused fetch -- triggering
            // `cancelWaiter`'s retraction. `markGenerationRetiring` runs
            // synchronously the moment this cancellation reaches the
            // actor (long before the reader above is ever released), and
            // the retraction's own memory/disk removal proceeds
            // concurrently with (not blocked by) the still-suspended
            // reader above, since `AssetMemoryCache`'s `get` and
            // `removeIfApplied` calls are independent actor hops.
            //
            // Releasing the fetch's own publish-pause lets that
            // cancellation actually run to completion; waiting until the
            // retraction has *fully* finished removing the entry from
            // both cache layers -- strictly *before* releasing the
            // reader below -- is what makes this test genuinely exercise
            // the "retraction already completed" case, not merely
            // "retraction still in flight".
            try await cancelCallerAndAwaitFullRetraction(
                callerTask: callerTask,
                publishGate: publishGate,
                memoryCache: layers.memoryCache,
                diskCache: layers.diskCache,
                cacheKey: cacheKey
            )

            // Only now -- with the retraction fully, durably complete --
            // does the second reader's own suspended `get` call finally
            // return the stale, already-captured entry back to
            // `asset(for:)` for its own authority check.
            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 6, height: 6)
            await layers.transport.enqueue(.success(successResult(body: freshBody)), for: urls[0])
            await readerGate.release()

            let readerResult = try await readerTask.value
            #expect(
                readerResult.payload == freshBody,
                """
                The second reader must never be served the abandoned, already-retracted entry \
                it happened to capture just before retraction: retiringGenerations must reject \
                it even though the retraction it depends on had, by this point, already fully \
                completed
                """
            )
            #expect(await layers.transport.callCount(for: urls[0]) == 2)
        }
    }

    /// Cancels `callerTask` -- the sole waiter of a still-paused
    /// fetch/revalidation -- releases `publishGate` so its own retraction
    /// can run to completion, waits for that retraction to fully clear
    /// `cacheKey` from `memoryCache`, and asserts both that no disk entry
    /// survives it and that `callerTask` itself completes with
    /// `CancellationError`. Shared by this file's tests purely to keep
    /// each test's own body under this package's `function_body_length`
    /// limit.
    private func cancelCallerAndAwaitFullRetraction(
        callerTask: Task<CachedAsset, Error>,
        publishGate: PauseGate,
        memoryCache: AssetMemoryCache,
        diskCache: AssetDiskCache,
        cacheKey: AssetCacheKey
    ) async throws {
        callerTask.cancel()
        await publishGate.release()
        await waitForMemoryEntryRetracted(memoryCache, cacheKey: cacheKey)
        let diskEntryAfterRetraction = try await diskCache.get(cacheKey)
        #expect(diskEntryAfterRetraction == nil)
        await #expect(throws: CancellationError.self) {
            _ = try await callerTask.value
        }
    }

    /// Seeds a real, validator-bearing entry for `key` via an ordinary
    /// unconditional fetch, so a subsequent revalidation has something
    /// to condition against. Shared purely to keep the test below under
    /// this package's `function_body_length` limit.
    private func seedValidatorBearingEntry(
        layers: ServiceLayers,
        key: AssetKey,
        urls: [URL]
    ) async throws {
        let seedBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
        await layers.transport.enqueue(
            .success(successResult(body: seedBody, etag: "\"v1\"")),
            for: urls[0]
        )
        let seeded = try await layers.service.asset(for: key)
        #expect(seeded.payload == seedBody)
        #expect(await layers.transport.callCount(for: urls[0]) == 1)
    }

    @Test(
        """
        A revalidation-path reader's memory-hit check must reject a retired generation even \
        though the narrower clearStateUnchanged(since:for:) check `revalidate(for:)` uses \
        deliberately ignores keyLatestToken churn (to tolerate legitimate coalescing) and would \
        otherwise report this entry unchanged: retiringGenerations is the *only* thing standing \
        between this reader and conditionally revalidating an already-abandoned entry using its \
        own (equally abandoned) ETag
        """
    )
    func revalidationReaderRejectsRetiredGenerationClearStateUnchangedCannotCatch() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let layers = try makeService(directory: root, limits: limits)

            // Seeds a real, validator-bearing entry via an ordinary
            // unconditional fetch, so the revalidation below has
            // something to condition against.
            try await seedValidatorBearingEntry(layers: layers, key: key, urls: urls)

            // A conditional revalidation for this same key receives a
            // fresh 200 (a new body, a new ETag), publishes it under a
            // freshly reserved ticket, and pauses immediately after that
            // publish has already landed in both cache layers.
            let abandonedBody = AssetImageFixtureBuilder.validAVIF(width: 5, height: 5)
            await layers.transport.enqueue(
                .success(successResult(body: abandonedBody, etag: "\"v2\"")),
                for: urls[0]
            )
            let (callerTask, publishGate) = await startCallerPausedAfterPublish(
                service: layers.service
            ) {
                try await layers.service.revalidate(for: key)
            }
            #expect(await layers.transport.callCount(for: urls[0]) == 2)
            let appliedDuringPause = await layers.memoryCache.get(cacheKey)
            #expect(appliedDuringPause?.payload == abandonedBody)
            #expect(appliedDuringPause?.metadata.etag == "\"v2\"")

            // A second, independent reader starts its own
            // `revalidate(for:)` call for the exact same key. Its own
            // `memoryCache.get` is paused immediately after it has
            // already captured `abandonedBody`'s entry (ETag `"v2"`),
            // but before that entry is returned back for this reader's
            // own memory-hit authority check.
            let (readerTask, readerGate) = await startReaderCapturingStaleMemoryHit(
                memoryCache: layers.memoryCache
            ) {
                try await layers.service.revalidate(for: key)
            }

            // Only now does the original caller cancel -- the sole
            // waiter of the still-paused revalidation -- triggering
            // `cancelRevalidationWaiter`'s retraction.
            // `markGenerationRetiring` runs synchronously the instant
            // this reaches the actor: strictly before the reader above
            // is ever released, and strictly before either cache layer's
            // own removal has actually completed.
            try await cancelCallerAndAwaitFullRetraction(
                callerTask: callerTask,
                publishGate: publishGate,
                memoryCache: layers.memoryCache,
                diskCache: layers.diskCache,
                cacheKey: cacheKey
            )

            // Only now -- with the retraction fully, durably complete,
            // and both cache layers holding no trustworthy entry for
            // this key at all -- does the reader's own suspended `get`
            // call finally return the stale, already-captured entry back
            // for its own memory-hit authority check.
            await readerGate.release()

            // The correct outcome is a thrown `staleConditionalResponse`
            // -- `revalidate(for:)`'s own documented contract for "no
            // currently trustworthy cached entry exists to condition
            // against" -- with **no second network call at all**: if
            // `retiringGenerations` were regressed away (leaving only
            // `clearStateUnchanged(since:for:)`, which this exact branch
            // deliberately does not check `keyLatestToken` in, precisely
            // so a legitimately coalescing second caller is never
            // wrongly rejected), this reader would instead wrongly trust
            // the abandoned `"v2"`-tagged entry as still current and
            // issue its own conditional network request against it --
            // an entirely avoidable third network call this reader must
            // never make, since the whole point of retracting the
            // abandoned publish was that nothing durable survives it.
            await #expect(throws: AssetError.staleConditionalResponse) {
                _ = try await readerTask.value
            }
            #expect(
                await layers.transport.callCount(for: urls[0]) == 2,
                """
                The reader must never have made a third network call at all: neither memory \
                nor disk holds a trustworthy entry for this key to condition a request against, \
                and clearStateUnchanged(since:for:) alone (ignoring keyLatestToken by design) \
                cannot detect that -- only retiringGenerations can
                """
            )
        }
    }
}
