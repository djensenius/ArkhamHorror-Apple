@testable import ArkhamHorrorShared
import Foundation
import Testing

/// The disk-fallback counterpart to
/// `AssetCacheServiceRetiringGenerationTests.swift`'s memory-hit tests
/// -- split into its own file purely to keep that file's own
/// `file_length` under this package's limit. Duplicates its own small
/// `PauseGate`/pause-helper set rather than sharing them across files,
/// following this suite's established per-file convention (see the
/// sibling file's own `PauseGate` doc comment).
extension AssetCacheServiceTests {
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

    /// Identical in shape to the sibling file's own helper of the same
    /// name.
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

    /// Identical in shape to the sibling file's own helper of the same
    /// name.
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

    /// Cancels `callerTask` -- the sole waiter of a still-paused fetch --
    /// releases `publishGate` so its retraction can proceed, and waits
    /// until that retraction's own disk-side removal is parked at
    /// `removalGate` -- i.e. strictly before it has touched disk at all
    /// -- then confirms disk still holds the abandoned entry, completely
    /// untouched. Shared purely to keep the sole test below under this
    /// package's `function_body_length` limit.
    private func cancelCallerAndAwaitRemovalGateEngaged(
        scenario: DiskFallbackScenario,
        expectedAbandonedETag: String
    ) async throws {
        scenario.callerTask.cancel()
        await scenario.publishGate.release()
        await scenario.removalGate.waitUntilStarted()
        let diskEntryStillPresent = try await scenario.layers.diskCache.get(scenario.cacheKey)
        #expect(diskEntryStillPresent?.metadata.etag == expectedAbandonedETag)
    }

    /// Bundles every fixture this file's sole test needs mid-flight:
    /// the wired service layers, the cache key/candidate URLs under
    /// test, the paused original caller and its publish-pause gate, the
    /// second reader paused just after capturing the stale memory hit,
    /// and the disk-removal pause gate -- extracted purely to keep the
    /// test below under this package's `function_body_length` limit.
    private struct DiskFallbackScenario {
        let layers: ServiceLayers
        let cacheKey: AssetCacheKey
        let urls: [URL]
        let callerTask: Task<CachedAsset, Error>
        let publishGate: PauseGate
        let readerTask: Task<CachedAsset, Error>
        let readerGate: PauseGate
        let removalGate: PauseGate
    }

    /// Seeds an abandoned, ETag-bearing entry; starts the original
    /// caller paused immediately after its own publish has landed; starts
    /// a second reader paused immediately after it captures that same
    /// (soon-to-be-stale) memory entry; and installs a pause immediately
    /// before the eventual retraction's disk-side removal acquires its
    /// exclusive lock -- i.e. strictly before it has touched disk at all.
    private func setUpDiskFallbackScenario(root: URL) async throws -> DiskFallbackScenario {
        let limits = standardLimits()
        let key = try cardArtKey()
        let urls = candidateURLs(for: key)
        let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)
        let layers = try makeService(directory: root, limits: limits)

        // The soon-to-be-abandoned entry carries a real ETag: without
        // one, `conditionalRevalidationTarget` would find no validator
        // and fall through to an ordinary fetch regardless of whether
        // the fix under test is present, making the two outcomes
        // indistinguishable.
        let abandonedBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
        await layers.transport.enqueue(
            .success(successResult(body: abandonedBody, etag: "\"abandoned\"")),
            for: urls[0]
        )

        let (callerTask, publishGate) = await startCallerPausedAfterPublish(
            service: layers.service
        ) {
            try await layers.service.asset(for: key)
        }
        #expect(await layers.memoryCache.get(cacheKey) != nil)

        let (readerTask, readerGate) = await startReaderCapturingStaleMemoryHit(
            memoryCache: layers.memoryCache
        ) {
            try await layers.service.asset(for: key)
        }

        let removalGate = PauseGate()
        await layers.diskCache.installTestOnlyPauseBeforeAcquiringRemovalLock {
            await removalGate.markStartedAndWaitForRelease()
        }

        return DiskFallbackScenario(
            layers: layers,
            cacheKey: cacheKey,
            urls: urls,
            callerTask: callerTask,
            publishGate: publishGate,
            readerTask: readerTask,
            readerGate: readerGate,
            removalGate: removalGate
        )
    }

    @Test(
        """
        A reader whose memory-hit check correctly rejects a retired generation must not then \
        have `asset(for:)`'s *disk-hit* fallback branch resurrect that exact same abandoned \
        entry from disk: `unchanged(since:for:)` alone is a pure self-consistency check against \
        a snapshot taken strictly after the retraction's own synchronous bookkeeping already \
        ran (so both its "before" and "after" reads trivially agree), and cannot detect that the \
        disk bytes it is about to trust are the very ones a still-in-flight, not-yet-completed \
        retraction already decided must never be served again. Only \
        authorityIsRetiring(_:for:), checked directly against the disk-read entry's own \
        stamped generation, closes this gap.
        """
    )
    func diskFallbackRejectsRetiringGenerationWhileRemovalStillInFlight() async throws {
        try await withScratchDirectory { root in
            let scenario = try await setUpDiskFallbackScenario(root: root)

            // Cancelling the original caller -- the sole waiter of the
            // still-paused fetch -- triggers `cancelWaiter`'s retraction.
            // `markGenerationRetiring` runs synchronously the instant
            // this reaches the actor; `memoryCache.removeIfApplied` then
            // runs to completion (a plain, single-hop, non-suspending
            // actor call); only then does `diskCache.removeIfApplied`
            // begin, immediately parking at `removalGate`, before it has
            // made any change to disk at all. Confirms the precise
            // window this test exercises: disk still holds the
            // abandoned entry, completely untouched.
            try await cancelCallerAndAwaitRemovalGateEngaged(
                scenario: scenario,
                expectedAbandonedETag: "\"abandoned\""
            )

            // Only now does the second reader's own suspended `get` call
            // return the stale, already-captured entry back to
            // `asset(for:)`. Its memory-hit authority check must reject
            // it (via `retiringGenerations`, proven by the sibling test
            // above), fall through to the disk-hit branch, read the
            // still-present-on-disk abandoned entry, and *that* check
            // must reject it too -- via this file's new
            // `authorityIsRetiring` disk-hit guard -- rather than
            // trusting it and issuing a conditional revalidation request
            // carrying the abandoned `"abandoned"` ETag.
            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 7, height: 7)
            await scenario.layers.transport.enqueue(
                .success(successResult(body: freshBody)),
                for: scenario.urls[0]
            )
            await scenario.readerGate.release()

            let readerResult = try await scenario.readerTask.value
            #expect(
                readerResult.payload == freshBody,
                """
                The disk-hit fallback must never resurrect the abandoned entry either: it must \
                fall all the way through to a genuine, unconditional fresh fetch
                """
            )
            let calls = await scenario.layers.transport.calls
            #expect(
                calls.allSatisfy { $0.ifNoneMatch != "\"abandoned\"" },
                """
                No request may ever have been sent conditioned on the abandoned entry's own \
                ETag: that would mean the disk-hit branch wrongly trusted disk bytes a \
                still-in-flight retraction had already decided must never be served again
                """
            )

            // Only now, with every assertion above already made against
            // the deliberately-still-untouched disk state, does this
            // test let the retraction's own disk removal actually
            // proceed and complete. `waitForMemoryEntryRetracted` is not
            // used here (unlike the sibling tests above): the reader's
            // own successful fresh fetch just published a brand new,
            // perfectly legitimate memory entry for this same key, so
            // "no entry at all" is not the expected end state.
            await scenario.removalGate.release()
            await #expect(throws: CancellationError.self) {
                _ = try await scenario.callerTask.value
            }
        }
    }
}
