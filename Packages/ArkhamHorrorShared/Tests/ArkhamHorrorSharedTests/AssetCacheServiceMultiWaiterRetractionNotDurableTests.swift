@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of this review round's finding #1: with
/// **two or more** waiters coalesced onto one shared fetch/revalidation
/// whose own `publish(_:asset:token:)`/`touch(_:asset:token:)` call
/// suffers a genuine, durable-write failure on its own final
/// `isAuthoritative(_:for:)` re-check (not a mere pause, and not this
/// suite's already-covered single-waiter-cancels-last scenario in
/// `AssetCacheServiceRetractionNotDurableTests.swift`), *every* waiter —
/// not only whichever one happens to finalize last — must observe the
/// exact same typed `AssetError` via
/// `AssetCacheService/WaiterFinalOutcome/retractionNotDurable(_:)`, never
/// a plain `.stale`/`.failed` outcome that silently discards the failed
/// retraction underneath it.
///
/// Reproduces "ticket1 published, ticket2 reserved during the final
/// check" via `AssetCacheService/issueToken(for:)` directly: a real,
/// in-process supersession of `keyLatestToken[cacheKey]` — exactly the
/// same effect a second, independent fetch/revalidation issuance for
/// this same key would have — without pre-emptively tombstoning disk
/// (unlike `invalidate(_:token:)`, which would also durably commit its
/// own retraction and leave nothing for this test's own fault injection
/// to actually fail). `AssetCacheService/testOnlyPauseBeforePublishFinalCAS`
/// is the new hook this fix introduces specifically so this exact window
/// — after `publish`/`touch`'s own disk write has already landed, but
/// before their final authority re-check — is reachable deterministically
/// rather than by incidental scheduling timing.
extension AssetCacheServiceTests {
    /// Identical in shape to this suite's other sibling race-test
    /// `PauseGate`s (not shared across files, by this suite's established
    /// convention).
    private actor MultiWaiterPauseGate {
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

    @Test(
        """
        Two waiters coalesced onto a fresh fetch whose publish() final check genuinely fails \
        to retract must BOTH observe the same typed retraction failure -- never only the \
        last-finalizing one
        """
    )
    func twoWaitersBothObserveFailedGroupRetractionAfterFreshFetch() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let layers = try makeService(directory: root, limits: limits)

            await layers.transport.hold(urls[0])
            await layers.transport.enqueue(.success(successResult()), for: urls[0])

            let gate = MultiWaiterPauseGate()
            await layers.service.installTestOnlyPauseBeforePublishFinalCAS {
                await gate.markStartedAndWaitForRelease()
            }

            let firstTask = Task { try await layers.service.asset(for: key) }
            let secondTask = Task { try await layers.service.asset(for: key) }
            await layers.transport.waitForCallCount(1, for: urls[0])
            try await waitForInFlightWaiterCount(2, for: key, on: layers.service)
            await layers.transport.release(urls[0])

            // Blocks inside `publish(_:asset:token:)` immediately after
            // its own disk write already landed (both cache layers now
            // durably say `content(ticket1)`) and strictly before its
            // final `isAuthoritative(_:for:)` re-check.
            await gate.waitUntilStarted()
            #expect(await layers.memoryCache.get(cacheKey) != nil)

            // "Ticket2 reserved during the final check": a fresh,
            // in-process issuance for this exact key, purely bumping
            // `keyLatestToken[cacheKey]` -- no disk write at all -- so
            // `publish`'s own paused token (ticket1) is no longer the
            // latest, but disk still durably says `content(ticket1)`,
            // leaving genuine work for the group's own retraction to do.
            _ = await layers.service.issueToken(for: cacheKey)

            // Fails the exact write the durable `.retiring` commit
            // performs (the merged per-key authority record's primary
            // copy), installed before releasing the pause so it is
            // unconditionally active by the time the group's retraction
            // attempts it.
            let appliedName = await layers.diskCache.appliedTicketFilename(for: cacheKey)
            await layers.diskCache.directoryAccess.installFaultInjection(
                failSuffixes: [appliedName]
            )

            await gate.release()

            let firstResult = await firstTask.result
            let secondResult = await secondTask.result
            assertRetractionNotDurableFailure(firstResult, waiterLabel: "first")
            assertRetractionNotDurableFailure(secondResult, waiterLabel: "second")

            // Disk must still durably report `.content`: the failed
            // `.retiring` commit never landed, so nothing was actually
            // retracted.
            let disposition = try await layers.diskCache.currentKeyDisposition(for: cacheKey)
            #expect(
                disposition.kind == .content,
                "A failed retraction commit must not have partially applied any transition"
            )
        }
    }

    @Test(
        """
        Two waiters coalesced onto a revalidation whose touch() final check genuinely fails \
        to retract must BOTH observe the same typed retraction failure -- never only the \
        last-finalizing one
        """
    )
    func twoWaitersBothObserveFailedGroupRetractionAfterRevalidation() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let layers = try makeService(directory: root, limits: limits)

            await layers.transport.enqueue(
                .success(successResult(etag: "\"v1\"")),
                for: urls[0]
            )
            let initial = try await layers.service.asset(for: key)
            #expect(initial.metadata.etag == "\"v1\"")

            await layers.transport.hold(urls[0])
            await layers.transport.enqueue(.success(.notModified), for: urls[0])

            let gate = MultiWaiterPauseGate()
            await layers.service.installTestOnlyPauseBeforePublishFinalCAS {
                await gate.markStartedAndWaitForRelease()
            }

            let firstTask = Task { try await layers.service.revalidate(for: key) }
            let secondTask = Task { try await layers.service.revalidate(for: key) }
            // Call count 2: the initial fetch (1) plus this single shared
            // revalidation fetch (2).
            await layers.transport.waitForCallCount(2, for: urls[0])
            try await waitForInFlightRevalidationWaiterCount(2, for: key, on: layers.service)
            await layers.transport.release(urls[0])

            // Blocks inside `touch(_:asset:token:)` immediately after its
            // own disk metadata write already landed, strictly before
            // its final `isAuthoritative(_:for:)` re-check.
            await gate.waitUntilStarted()

            // "Ticket2 reserved during the final check", identical in
            // spirit to the fresh-fetch test above.
            _ = await layers.service.issueToken(for: cacheKey)

            let appliedName = await layers.diskCache.appliedTicketFilename(for: cacheKey)
            await layers.diskCache.directoryAccess.installFaultInjection(
                failSuffixes: [appliedName]
            )

            await gate.release()

            let firstResult = await firstTask.result
            let secondResult = await secondTask.result
            assertRetractionNotDurableFailure(firstResult, waiterLabel: "first")
            assertRetractionNotDurableFailure(secondResult, waiterLabel: "second")

            // The pre-existing entry's own disposition must still
            // durably report `.content`: the failed `.retiring` commit
            // never landed, so nothing was actually retracted.
            let disposition = try await layers.diskCache.currentKeyDisposition(for: cacheKey)
            #expect(
                disposition.kind == .content,
                "A failed retraction commit must not have partially applied any transition"
            )
        }
    }
}

/// Asserts that `result` carries the exact typed failure a *durably
/// confirmed* group retraction failure must produce
/// (`AssetError/cachePersistenceFailed(_:)`, this suite's fault
/// injection's own signature) — deliberately **not** merely "some
/// `AssetError` that is not `CancellationError`"
/// (`AssetCacheServiceRetractionNotDurableTests.swift`'s own
/// `assertTypedFailureNotCancellation`, reused by its single-waiter test):
/// the prior revision's bug produced `AssetError/staleOperation` for
/// every non-retracting waiter regardless of whether the group's shared
/// retraction ever actually succeeded — itself a distinct, valid
/// `AssetError` case that a weaker "is a typed AssetError" check cannot
/// tell apart from this fix's own, correctly-broadcast
/// `.retractionNotDurable(_:)` outcome. Only this exact case
/// distinguishes "every waiter learned the retraction genuinely failed"
/// from "every waiter merely learned the shared operation itself was not
/// a success", which is exactly what a prior revision already reported
/// regardless of this fix.
func assertRetractionNotDurableFailure(
    _ result: Result<CachedAsset, Error>,
    waiterLabel: String
) {
    switch result {
    case .success:
        Issue.record("[\(waiterLabel)] Expected a thrown error, got a successful result")
    case let .failure(error):
        guard case let AssetError.cachePersistenceFailed(detail)? = error as? AssetError else {
            let message = """
            [\(waiterLabel)] Expected AssetError.cachePersistenceFailed (the group's own \
            durably-confirmed retraction failure), got \(error) -- a prior revision's bug \
            could produce a *different* typed AssetError (e.g. .staleOperation) for a \
            non-last waiter without ever synchronizing against whether the group's shared \
            retraction actually succeeded, which a merely "is some AssetError" check cannot \
            distinguish from this fix's own outcome
            """
            Issue.record("\(message)")
            return
        }
        #expect(
            !detail.isEmpty,
            "[\(waiterLabel)] Expected a non-empty underlying I/O failure description"
        )
    }
}
