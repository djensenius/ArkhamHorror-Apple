@testable import ArkhamHorrorShared
import Foundation
import Testing

/// The revalidation mirror of `AssetCacheServiceRetractionNotDurableTests.swift`
/// -- proves the identical fix in
/// ``AssetCacheService/coalescedRevalidation``
/// (`AssetCacheService+RevalidationCoalescing.swift`): cancelling the sole
/// waiter of an already-applied revalidation whose durable `.retiring`
/// commit genuinely fails must surface that commit's own typed
/// `AssetError` to the caller, never plain cancellation. See that sibling
/// file's own type-level doc comment for the exact defect this closes,
/// and for why disk resolves *forward* to `.tombstone` rather than
/// reverting to `.content` afterward: before the fix,
/// ``AssetCacheService/cancelRevalidationWaiter(_:fetchID:waiterID:)``
/// already resumed this waiter with the typed failure, but
/// `coalescedRevalidation`'s own unconditional re-derivation of the
/// final outcome (via
/// `finalizeRevalidationWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:)`)
/// discarded it and threw plain `CancellationError()` regardless.
extension AssetCacheServiceTests {
    @Test(
        """
        Cancelling the sole waiter of an already-applied revalidation whose durable \
        `.retiring` commit genuinely fails must report the underlying typed error to the \
        caller -- never plain cancellation -- and disk must resolve forward to `.tombstone` \
        afterward, since phase 2's own unconditional detached cleanup durably completes via \
        the mirror's own already-landed writes
        """
    )
    func revalidationCancellationWithFailedRetiringCommitReportsTypedFailure() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let layers = try makeService(directory: root, limits: limits)

            // Seeds an initial, validator-bearing entry so `revalidate(for:)`
            // below performs a genuine conditional request rather than an
            // unconditional fetch.
            await layers.transport.enqueue(
                .success(successResult(etag: "\"v1\"")),
                for: urls[0]
            )
            _ = try await layers.service.asset(for: key)

            let refreshedBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            await layers.transport.enqueue(
                .success(successResult(body: refreshedBody, etag: "\"v2\"")),
                for: urls[0]
            )

            // Pauses the shared revalidation's own task body immediately
            // after its `publish(_:asset:token:)` call has already
            // returned `.applied` -- identical timing convention to the
            // plain-fetch sibling test.
            let gate = RevalidationPublishPauseGate()
            await layers.service.installTestOnlyPauseAfterFetchPublishApplied {
                await gate.markStartedAndWaitForRelease()
            }

            let callerTask = Task { try await layers.service.revalidate(for: key) }
            await gate.waitUntilStarted()

            // Fails only the *primary* copy's own write of the durable
            // `.retiring` commit, installed before cancellation so it is
            // unconditionally active by the time the cancellation-
            // triggered retraction attempts that write. The anchor and
            // mirror copies (always written first) still durably land.
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

            // Disk must now durably report `.tombstone` for the refreshed
            // (v2) publication: `cancelRevalidationWaiter` fires phase 2
            // (``completeDurableRetractionIfApplied(_:token:)``)
            // unconditionally in its own detached `Task`, regardless of
            // whether phase 1 threw to this caller. Phase 2 reads the
            // disposition fresh -- reconciling to the mirror's
            // already-durable `.retiring` -- and proceeds to commit
            // `.tombstone`, whose primary write fails identically but
            // whose mirror/anchor again durably land. An unresolved
            // `.tombstone` disposition is never served by `get(_:)`.
            let disposition = try await layers.diskCache.currentKeyDisposition(for: cacheKey)
            let dispositionMessage = """
            Disk must report `.tombstone`: phase 2's own detached cleanup fires \
            unconditionally after phase 1's local throw and durably completes via the \
            mirror's own already-landed writes
            """
            #expect(disposition.kind == .tombstone, "\(dispositionMessage)")
            let onDisk = try await layers.diskCache.get(cacheKey)
            #expect(onDisk == nil, "An unresolved `.retiring` disposition must never be served")
        }
    }
}

/// A minimal start/release rendezvous, identical in shape to this
/// suite's plain-fetch sibling `PublishPauseGate` -- named distinctly
/// purely to avoid a redeclaration clash within the same module.
private actor RevalidationPublishPauseGate {
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
