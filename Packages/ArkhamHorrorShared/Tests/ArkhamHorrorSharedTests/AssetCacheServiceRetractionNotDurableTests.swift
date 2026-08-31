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
/// **Disk's own resulting state.** The fault this test installs only
/// fails the primary copy's own write -- the mirror (always written
/// first, see `AssetDiskCache+Disposition+Commit.swift`'s own doc
/// comment) still durably lands every transition before the primary's
/// own write fails. `cancelWaiter` fires phase 2
/// (``AssetCacheService/completeDurableRetractionIfApplied(_:token:)``)
/// unconditionally in its own detached `Task`, regardless of whether
/// phase 1 threw to *this* caller -- unlike `retractUndeliveredMutation`
/// (this suite's multi-waiter sibling tests), whose phase-1 throw
/// prevents phase 2 from ever being scheduled at all. Phase 2 reads the
/// disposition fresh, reconciles to the mirror's already-durable
/// `.retiring`, and proceeds to commit `.tombstone`, whose primary write
/// fails identically but whose mirror/anchor again durably land -- so
/// the reconciled authority record ends this test at `.tombstone`, not
/// `.retiring`.
extension AssetCacheServiceTests {
    @Test(
        """
        Cancelling the sole waiter of an already-applied fetch whose durable `.retiring` \
        commit genuinely fails (a write failure, not a mere pause) must report the underlying \
        typed error to the caller -- never plain cancellation -- and disk must resolve forward \
        to `.tombstone` afterward, since phase 2's own unconditional detached cleanup durably \
        completes via the mirror's own already-landed writes
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

            // Fails only the *primary* copy's own write of the durable
            // `.retiring` commit (`AssetDiskCache+Disposition.swift`'s
            // merged authority record, at the `.applied` filename) --
            // installed before cancellation so it is unconditionally
            // active by the time the cancellation-triggered retraction
            // attempts that write. The anchor and mirror copies (always
            // written first -- see `AssetDiskCache+Disposition+Commit.swift`)
            // still durably land, which is exactly what lets the
            // reconciled disposition resolve forward to `.retiring`
            // below rather than reverting to `.content`.
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

            // Disk must now durably report `.tombstone`, not the pre-
            // retraction `.content`: unlike this suite's multi-waiter
            // sibling tests (which use `retractUndeliveredMutation` --
            // whose phase-1 throw prevents phase 2 from ever being
            // scheduled), `cancelWaiter` fires phase 2
            // (``completeDurableRetractionIfApplied(_:token:)``)
            // unconditionally in its own detached `Task`, regardless of
            // whether phase 1 threw to *this* caller. Phase 2's own
            // guard reads the disposition fresh -- reconciling to the
            // mirror's already-durable `.retiring` (mirror-first write
            // landed even though the primary's failed) -- so it proceeds
            // to commit `.tombstone`, whose primary write fails
            // identically but whose mirror/anchor again durably land,
            // reconciling forward once more. A caller told
            // `retractionNotDurable` must never assume content was
            // safely rolled back, but it also must never assume the
            // prior `.content` publication is still servable: both
            // `.retiring` and `.tombstone` are unreadable exactly alike.
            let disposition = try await layers.diskCache.currentKeyDisposition(for: cacheKey)
            let dispositionMessage = """
            Disk must report `.tombstone`: phase 2's own detached cleanup fires \
            unconditionally after phase 1's local throw and durably completes via the \
            mirror's own already-landed writes
            """
            #expect(disposition.kind == .tombstone, "\(dispositionMessage)")
            let hit = try await layers.diskCache.get(cacheKey)
            #expect(hit == nil, "An unresolved `.tombstone` disposition must never be served")
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
