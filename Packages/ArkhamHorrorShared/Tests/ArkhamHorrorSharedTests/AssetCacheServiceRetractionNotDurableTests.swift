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
/// outcome, and disk must still report `.content` afterward (nothing
/// was actually retracted).
extension AssetCacheServiceTests {
    @Test(
        """
        Cancelling the sole waiter of an already-applied fetch whose durable `.retiring` \
        commit genuinely fails (a write failure, not a mere pause) must report the underlying \
        typed error to the caller -- never plain cancellation -- and disk must \
        still report `.content` afterward, since nothing was actually retracted
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

            // Fails the exact write the durable `.retiring` commit
            // performs (`AssetDiskCache+Disposition.swift`'s merged
            // authority record, at the single `.applied` filename) --
            // installed before cancellation so it is unconditionally
            // active by the time the cancellation-triggered retraction
            // attempts that write.
            let appliedName = await layers.diskCache.appliedTicketFilename(for: cacheKey)
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

            // Disk must still durably report `.content`: the `.retiring`
            // commit's own write failed, so nothing was actually
            // retracted -- a caller told `retractionNotDurable` must
            // never assume content was safely rolled back.
            let disposition = try await layers.diskCache.currentKeyDisposition(for: cacheKey)
            let dispositionMessage = """
            Disk must still report `.content`: the failed write must not have \
            partially applied any transition
            """
            #expect(disposition.kind == .content, "\(dispositionMessage)")
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
