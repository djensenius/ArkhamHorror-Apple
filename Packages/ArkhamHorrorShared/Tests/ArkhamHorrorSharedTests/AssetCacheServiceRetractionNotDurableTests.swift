@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of this review round's finding #1, the
/// half not already covered by
/// `AssetCacheServiceDurableRetirementOrderingTests.swift`: that file
/// proves cancellation cannot resolve *before* the durable `.retiring`
/// commit lands, but never exercises the commit *genuinely failing*
/// (rather than merely being paused).
///
/// Before this fix, even though
/// ``AssetCacheService/cancelWaiter(_:fetchID:waiterID:)`` already
/// resumed a genuinely-failed commit's sole waiter with the typed
/// `AssetError` (never plain cancellation) at its own `continuation`,
/// ``AssetCacheService/coalescedFetch(key:cacheKey:candidates:)`` (and
/// its revalidation mirror) unconditionally re-derived the final
/// outcome afterward via
/// `finalizeFetchWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:)`,
/// which bases `.cancelled` purely on `Task.isCancelled` — discarding
/// that already-resumed typed failure and throwing plain
/// `CancellationError()` to the caller regardless, exactly as if the
/// commit had succeeded, even though disk still durably says
/// `.content`. This test proves the fix: a genuine write failure during
/// that exact commit must surface to the cancelling caller as its own
/// typed `AssetError`, never folded into an ordinary cancellation
/// outcome.
///
/// **Disk's own resulting state.** There is exactly one canonical
/// authority record per key, atomically replaced (temp + fsync + rename
/// + directory fsync) and never mirrored, so a fault that fails that
/// write fails the whole transition: no half of it lands, and the
/// durable disposition is left *exactly* as it was, still `.content`.
/// `cancelWaiter` does still fire phase 2
/// (``AssetCacheService/completeDurableRetractionIfApplied(_:token:)``)
/// unconditionally in its own detached `Task`, but that phase reads the
/// disposition fresh, correctly observes it is not `.retiring`, and
/// therefore has nothing to complete. That is the *point* of collapsing
/// to one file: a failed retraction is a clean no-op that fails closed
/// with a typed error, never a torn state some second copy has to
/// reconcile forward from. The caller is told `retractionNotDurable`
/// precisely so it cannot assume the retraction happened -- and, equally,
/// must not assume the prior publication was rolled back, because it
/// verifiably was not.
extension AssetCacheServiceTests {
    @Test(
        """
        Cancelling the sole waiter of an already-applied fetch whose durable `.retiring` \
        commit genuinely fails (a write failure, not a mere pause) must report the underlying \
        typed error to the caller -- never plain cancellation -- and must leave the single \
        canonical authority record exactly as it was, still `.content`, never torn or \
        partially advanced
        """
    )
    func cancellationWithFailedRetiringCommitReportsTypedFailure() async throws {
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

            // Pauses the shared fetch's own task body immediately after
            // its `publish(_:asset:token:)` call has already returned
            // `.applied` -- deterministic timing, matching this suite's
            // established convention, so the fault injection below is
            // guaranteed active before this test's cancellation ever
            // triggers the retraction it targets.
            let gate = PublishPauseGate()
            await layers.service.installTestOnlyPauseAfterFetchPublishApplied {
                await gate.markStartedAndWaitForRelease()
            }

            let callerTask = Task { try await layers.service.asset(for: key) }
            await gate.waitUntilStarted()
            #expect(await layers.memoryCache.get(cacheKey) != nil)

            // Fails the durable `.retiring` commit's own write of the
            // single canonical authority record
            // (`AssetDiskCache+Disposition.swift`, at the `.applied`
            // filename) -- installed before cancellation so it is
            // unconditionally active by the time the
            // cancellation-triggered retraction attempts that write.
            // There is no second copy: the whole transition simply does
            // not land.
            let appliedName = await layers.diskCache.authorityRecordFilename(for: cacheKey)
            await layers.diskCache.directoryAccess.installFaultInjection(
                failSuffixes: [appliedName]
            )

            callerTask.cancel()
            await gate.release()

            let result = await callerTask.result
            assertTypedFailureNotCancellation(result)

            let failure = await layers.service.lastDiskPersistenceFailure
            #expect(
                failure != nil,
                "The genuine durable-commit write failure must be recorded for auditing"
            )

            // Disk must still durably report exactly the pre-retraction
            // `.content`: the atomic single-file write either lands
            // whole or not at all, and this one did not land. Phase 2
            // (``completeDurableRetractionIfApplied(_:token:)``) still
            // fires unconditionally in its own detached `Task` after
            // phase 1's local throw, but its own fresh disposition read
            // correctly finds nothing in `.retiring` to complete, so it
            // is a no-op rather than a second chance to advance state a
            // failed write never reached. A caller told
            // `retractionNotDurable` must never assume content was
            // safely rolled back -- here it verifiably was not.
            let disposition = try await layers.diskCache.currentKeyDisposition(for: cacheKey)
            #expect(
                disposition.kind == .content,
                """
                A failed single-file authority write must leave the durable disposition \
                exactly as it was -- never torn, never partially advanced
                """
            )
            let hit = try await layers.diskCache.get(cacheKey)
            #expect(
                hit != nil,
                """
                The prior publication remains readable precisely because its retraction was \
                reported as not durable rather than silently assumed to have happened
                """
            )
        }
    }
}

/// Shared assertion for both this file's and its revalidation mirror's
/// single test: the cancelled caller's result must carry the failed
/// durable commit's own typed `AssetError`, never plain cancellation.
func assertTypedFailureNotCancellation(_ result: Result<CachedAsset, Error>) {
    switch result {
    case .success:
        Issue.record("Expected a thrown error, got a successful result")
    case let .failure(error):
        guard error is AssetError else {
            let message = """
            Expected a typed AssetError from the failed durable commit, got \(error) \
            -- a genuinely failed durable commit must never be reported as plain \
            cancellation
            """
            Issue.record("\(message)")
            return
        }
        let message = """
        A genuinely failed durable `.retiring` commit must never be folded into \
        plain cancellation
        """
        #expect(!(error is CancellationError), "\(message)")
    }
}

/// A minimal start/release rendezvous, identical in shape to this
/// suite's other sibling race-test `PauseGate`s (not shared across
/// files, by this suite's established convention) -- named distinctly
/// here purely to avoid a redeclaration clash with sibling files in the
/// same module that also declare a private `PauseGate` type.
private actor PublishPauseGate {
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
