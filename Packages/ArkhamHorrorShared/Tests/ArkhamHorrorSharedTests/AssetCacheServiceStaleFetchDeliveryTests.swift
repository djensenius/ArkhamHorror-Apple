@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of this review round's finding #3, for the
/// plain-fetch coalescing path specifically (`AssetCacheService+Coalescing.swift`'s
/// `coalescedFetch(key:cacheKey:candidates:)`, cited at lines 133-143) --
/// every sibling test that already proves "an older-issued operation
/// cannot outrank a newer, still-pending one" for the same key
/// (`AssetCacheServiceRevalidationCoalescingTests.swift`'s
/// `olderIssuedFastCompletionCannotOutrankNewerIssuedStillInFlight`/
/// `oldDelayed200CannotOverwriteANewer200`/
/// `delayedStale304CannotResurrectAfterADefinitiveNotFound`, and
/// `CrossServiceAuthorityTests.swift`'s
/// `olderIssuedFetchCannotOverwriteNewerSiblingFetch`) constructs its
/// "newer, still-pending operation" either as a `revalidate(for:)` call
/// (a separate in-flight dictionary from plain fetches, so it can
/// genuinely coexist with an in-flight plain fetch for the same key
/// without the two coalescing into one) or a second, independent
/// service instance -- neither exercises `coalescedFetch`'s own final
/// authority re-check (this file's target) with two distinct plain-fetch
/// tickets for the exact same key within *one* service instance, since
/// ``AssetCacheService/resolveOrCreateInFlightFetch(key:cacheKey:candidates:)``
/// always joins an existing in-flight plain fetch for the same key
/// rather than ever letting two coexist. The only place within one
/// service instance a second, genuinely independent plain-fetch ticket
/// *can* be issued for the same key while an older one's outcome is
/// still unresolved is after the older ticket's own underlying `Task`
/// has already completed (clearing it from `inFlight`) but before its
/// own waiter has performed its final authority re-check -- exactly the
/// window ``AssetCacheService/testOnlyPauseBeforeFetchWaiterFinalCAS``
/// exists to freeze deterministically.
extension AssetCacheServiceTests {
    @Test(
        """
        An older fetch ticket's own result has already been produced (its network fetch and \
        publish both already durably succeeded), but its own waiter is paused strictly before \
        its final authority re-check; once a newer, independently-issued fetch ticket for the \
        same key has since completed and durably superseded it, the older ticket's own waiter \
        must observe `staleOperation`, never its own now-superseded bytes
        """
    )
    func fetchWaiterPausedBeforeFinalCASIsRejectedAsStale() async throws {
        try await withScratchDirectory { directory in
            let layers = try makeService(directory: directory, limits: standardLimits())
            let memoryCache = layers.memoryCache
            let diskCache = layers.diskCache
            let transport = layers.transport
            let service = layers.service

            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let cacheKey = AssetCacheKey(
                for: key,
                candidates: AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            )

            let bodyA = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            let bodyB = AssetImageFixtureBuilder.validAVIF(width: 8, height: 8)

            // Only ticket A's own waiter must actually pause here: this
            // same hook fires for every ``coalescedFetch(key:cacheKey:candidates:)``
            // waiter in this test (ticket B's own single waiter
            // included), so this closure only blocks its *first*
            // invocation.
            let gate = FinalCASPauseGate()
            await service.installTestOnlyPauseBeforeFetchWaiterFinalCAS {
                await gate.pauseOnlyOnFirstCall()
            }

            await transport.enqueue(.success(successResult(body: bodyA)), for: urls[0])
            let taskA = Task { try await service.asset(for: key) }
            await gate.waitUntilFirstCallStarted()

            // Ticket A's own bytes are already durably published at this
            // exact moment -- its network fetch and disk write have both
            // already completed and its `inFlight` entry has already been
            // cleared -- only its own waiter's final authority re-check
            // remains paused.
            let afterAPublish = try await diskCache.get(cacheKey)
            #expect(
                afterAPublish?.payload == bodyA,
                "Ticket A's own publish must already be durable before this test proceeds"
            )

            try await service.invalidate(cacheKey)

            await transport.enqueue(.success(successResult(body: bodyB)), for: urls[0])
            let resultB = try await service.asset(for: key)
            #expect(resultB.payload == bodyB)

            // Ticket B's own independent fetch/publish durably
            // superseded ticket A's bytes before ticket A's paused
            // waiter is ever released.
            let afterBPublish = try await diskCache.get(cacheKey)
            #expect(afterBPublish?.payload == bodyB)

            await gate.release()

            await #expect(throws: AssetError.staleOperation) {
                _ = try await taskA.value
            }

            // Both cache layers must still hold ticket B's bytes: ticket
            // A's own rejected delivery must never have overwritten them
            // on its way out.
            let memoryAfter = await memoryCache.get(cacheKey)
            #expect(memoryAfter?.payload == bodyB)
            let diskAfter = try await diskCache.get(cacheKey)
            #expect(diskAfter?.payload == bodyB)
        }
    }
}

/// A minimal start/release rendezvous that only actually pauses its
/// *first* caller -- every subsequent call to
/// ``pauseOnlyOnFirstCall()`` returns immediately, since
/// `testOnlyPauseBeforeFetchWaiterFinalCAS` is one shared hook fired by
/// every plain-fetch waiter in the same test, not just the one this test
/// means to hold. Named distinctly from this suite's other sibling
/// `PauseGate`-shaped types (not shared across files, by this suite's
/// established convention) purely to avoid a redeclaration clash within
/// the same module.
private actor FinalCASPauseGate {
    private var hasBeenCalledOnce = false
    private var hasStarted = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseOnlyOnFirstCall() async {
        guard !hasBeenCalledOnce else { return }
        hasBeenCalledOnce = true
        hasStarted = true
        for continuation in startContinuations {
            continuation.resume()
        }
        startContinuations.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilFirstCallStarted() async {
        if hasStarted {
            return
        }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
