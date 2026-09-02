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
/// and for why a failed single-file authority write leaves the durable
/// disposition exactly as it was rather than partially advancing it:
/// before the fix,
/// ``AssetCacheService/cancelRevalidationWaiter(_:fetchID:waiterID:)``
/// already resumed this waiter with the typed failure, but
/// `coalescedRevalidation`'s own unconditional re-derivation of the
/// final outcome (via
/// `finalizeRevalidationWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:)`)
/// discarded it and threw plain `CancellationError()` regardless.
extension AssetCacheServiceTests {
    /// Seeds an initial, validator-bearing entry (so `revalidate(for:)`
    /// performs a genuine conditional request rather than an
    /// unconditional fetch) and queues the refreshed `v2` response the
    /// revalidation under test will receive. Factored out purely to keep
    /// the test body within this package's `function_body_length`
    /// convention.
    private func seedEntryAndEnqueueRefresh(
        _ layers: ServiceLayers,
        key: AssetKey,
        url: URL
    ) async throws {
        await layers.transport.enqueue(.success(successResult(etag: "\"v1\"")), for: url)
        _ = try await layers.service.asset(for: key)
        let refreshedBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
        await layers.transport.enqueue(
            .success(successResult(body: refreshedBody, etag: "\"v2\"")),
            for: url
        )
    }

    @Test(
        """
        Cancelling the sole waiter of an already-applied revalidation whose durable \
        `.retiring` commit genuinely fails must report the underlying typed error to the \
        caller -- never plain cancellation -- and must leave the single canonical authority \
        record exactly as it was, still `.content`, never torn or partially advanced
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

            try await seedEntryAndEnqueueRefresh(layers, key: key, url: urls[0])

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

            // Fails the durable `.retiring` commit's own write of the
            // single canonical authority record, installed before
            // cancellation so it is unconditionally active by the time
            // the cancellation-triggered retraction attempts that write.
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
            // `.content` for the refreshed (v2) publication:
            // `cancelRevalidationWaiter` does still fire phase 2
            // (``completeDurableRetractionIfApplied(_:token:)``)
            // unconditionally in its own detached `Task`, but that phase
            // reads the disposition fresh, finds nothing in `.retiring`
            // to complete, and is therefore a clean no-op -- there is no
            // second copy for it to reconcile forward from.
            let disposition = try await layers.diskCache.currentKeyDisposition(for: cacheKey)
            #expect(
                disposition.kind == .content,
                """
                A failed single-file authority write must leave the durable disposition \
                exactly as it was -- never torn, never partially advanced
                """
            )
            let onDisk = try await layers.diskCache.get(cacheKey)
            #expect(
                onDisk != nil,
                """
                The prior publication remains readable precisely because its retraction was \
                reported as not durable rather than silently assumed to have happened
                """
            )
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
