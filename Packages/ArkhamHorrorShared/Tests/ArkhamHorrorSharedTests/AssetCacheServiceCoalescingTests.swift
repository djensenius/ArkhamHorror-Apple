@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coalesced-fetch waiter-cancellation coverage for ``AssetCacheService``,
/// split out of `AssetCacheServiceTests.swift` (which retains the shared
/// `withService`/`cardArtKey`/`candidateURLs` helpers) purely to stay
/// under SwiftLint's `type_body_length`/`file_length`, the same way
/// `AssetCacheServiceRevalidationTests` is split by concern into its own
/// file.
extension AssetCacheServiceTests {
    // MARK: - Coalescing

    @Test("Two concurrent identical requests are coalesced onto a single network fetch")
    func concurrentIdenticalRequestsCoalesce() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.hold(urls[0])
            await transport.enqueue(.success(successResult()), for: urls[0])

            async let first = service.asset(for: key)
            async let second = service.asset(for: key)
            // Coalescing means only one real network fetch ever starts;
            // wait for that single fetch to begin, then give the second
            // caller time to join the in-flight work rather than starting
            // its own (which would show up as a second call once released).
            await transport.waitForCallCount(1, for: urls[0])
            try await Task.sleep(nanoseconds: 20_000_000)
            await transport.release(urls[0])

            let (firstResult, secondResult) = try await (first, second)
            #expect(firstResult.payload == secondResult.payload)
            let callCount = await transport.callCount(for: urls[0])
            #expect(
                callCount == 1,
                "Only one network fetch should have started for two identical concurrent requests"
            )
        }
    }

    @Test("One waiter cancelling does not corrupt or cancel the shared fetch for the other waiter")
    func oneWaiterCancellingDoesNotAffectOthers() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.hold(urls[0])
            await transport.enqueue(.success(successResult()), for: urls[0])

            let firstTask = Task { try await service.asset(for: key) }
            let secondTask = Task { try await service.asset(for: key) }
            await transport.waitForCallCount(1, for: urls[0])
            // Waits for both waiters to have genuinely joined the same
            // coalesced fetch, rather than a fixed `Task.sleep` guess --
            // real internal state, immune to scheduler jitter under load.
            try await waitForInFlightWaiterCount(2, for: key, on: service)

            firstTask.cancel()
            // Waits for the cancellation handler to actually finish
            // (removing firstTask's waiter, leaving only secondTask's)
            // before releasing the held fetch, for the same reason.
            try await waitForInFlightWaiterCount(1, for: key, on: service)
            await transport.release(urls[0])

            let firstResult = await firstTask.result
            #expect(
                throws: (any Error).self,
                """
                A cancelled waiter must always observe cancellation, even though the shared \
                fetch it was attached to went on to succeed for the other waiter
                """
            ) { try firstResult.get() }
            if case let .failure(error) = firstResult {
                #expect(
                    error is CancellationError,
                    "Expected CancellationError, got \(error)"
                )
            }

            let secondResult = try await secondTask.value
            #expect(secondResult.payload == AssetImageFixtureBuilder.validAVIF(
                width: 4,
                height: 4
            ))
            let callCount = await transport.callCount(for: urls[0])
            #expect(callCount == 1, "The shared fetch must not have been restarted or duplicated")
        }
    }

    @Test(
        """
        A waiter that cancels while the shared fetch it joined ultimately succeeds (because \
        another waiter is still attached) must still observe CancellationError itself, never \
        the shared success value — regardless of whether its own cancellation cleanup or the \
        shared fetch's own completion reaches the actor first
        """
    )
    func canceledWaiterNeverObservesASharedSuccessItDidNotWaitFor() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.hold(urls[0])
            await transport.enqueue(.success(successResult()), for: urls[0])

            let canceledTask = Task { try await service.asset(for: key) }
            let survivingTask = Task { try await service.asset(for: key) }
            await transport.waitForCallCount(1, for: urls[0])
            // Waits for both waiters to have genuinely joined before
            // racing the cancellation below -- see
            // `oneWaiterCancellingDoesNotAffectOthers()` for why this
            // must not be a fixed `Task.sleep` guess. Deliberately does
            // *not* also wait for the cancellation handler itself to
            // finish afterward: this test's whole point is to exercise
            // both possible orderings of that cleanup racing the shared
            // fetch's own completion.
            try await waitForInFlightWaiterCount(2, for: key, on: service)

            canceledTask.cancel()
            await transport.release(urls[0])

            let canceledResult = await canceledTask.result
            #expect(throws: (any Error).self) { try canceledResult.get() }
            if case let .failure(error) = canceledResult {
                #expect(error is CancellationError, "Expected CancellationError, got \(error)")
            }

            let survivingResult = try await survivingTask.value
            #expect(survivingResult.payload == AssetImageFixtureBuilder.validAVIF(
                width: 4,
                height: 4
            ))
        }
    }

    @Test("The last waiter cancelling stops the fetch and leaves no cache entry behind")
    func lastWaiterCancellingLeavesNoCacheEntry() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.hold(urls[0])
            await transport.enqueue(.success(successResult()), for: urls[0])

            let onlyTask = Task { try await service.asset(for: key) }
            await transport.waitForCallCount(1, for: urls[0])
            try await Task.sleep(nanoseconds: 20_000_000)

            onlyTask.cancel()
            let result = await onlyTask.result
            #expect(throws: (any Error).self) { try result.get() }

            // Release afterward so the fake transport's internal polling
            // loop doesn't spin forever; the fetch's own task should
            // already have been cancelled by this point regardless.
            await transport.release(urls[0])

            // A second, independent request must perform its own fresh
            // network fetch (callCount goes from 1 to 2) rather than
            // finding any entry the cancelled fetch might have published:
            // the cancelled fetch must never have reached `publish`.
            let secondAttempt = try await service.asset(for: key)
            #expect(
                secondAttempt.payload == AssetImageFixtureBuilder
                    .validAVIF(width: 4, height: 4),
                "A later, independent request must still succeed normally"
            )
            let callCount = await transport.callCount(for: urls[0])
            #expect(
                callCount == 2,
                """
                The cancelled fetch must never have published a cache entry the second \
                attempt could have been served from instead of hitting the network again
                """
            )
        }
    }

    @Test(
        """
        Cancelling the sole waiter while its fetch is still pending starts entirely fresh work \
        for a caller that joins immediately afterward, rather than attaching to (and being torn \
        down along with) the already-cancelled fetch
        """
    )
    func joinAfterZeroWaiterCancellationStartsFreshWork() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.hold(urls[0])
            await transport.enqueue(.success(successResult()), for: urls[0])
            await transport.enqueue(.success(successResult()), for: urls[0])

            let firstTask = Task { try await service.asset(for: key) }
            await transport.waitForCallCount(1, for: urls[0])
            try await Task.sleep(nanoseconds: 20_000_000)

            // Cancelling the only waiter must synchronously (from the
            // actor's perspective) remove the in-flight entry, so the very
            // next call below cannot possibly still find and join it.
            firstTask.cancel()
            try await Task.sleep(nanoseconds: 20_000_000)

            // Joins immediately after the zero-waiter cancellation, while
            // the old fetch's network call is still held (and about to be
            // torn down): this must start a brand new fetch rather than
            // attach to the dying one, which would otherwise incorrectly
            // observe the old fetch's cancellation instead of succeeding.
            let secondTask = Task { try await service.asset(for: key) }
            await transport.waitForCallCount(2, for: urls[0])
            await transport.release(urls[0])

            let firstResult = await firstTask.result
            #expect(throws: (any Error).self) { try firstResult.get() }

            let secondResult = try await secondTask.value
            #expect(
                secondResult.payload == AssetImageFixtureBuilder.validAVIF(width: 4, height: 4),
                """
                A caller joining right after a zero-waiter cancellation must get a freshly \
                started, independently successful fetch
                """
            )
            let callCount = await transport.callCount(for: urls[0])
            #expect(
                callCount == 2,
                """
                The second caller must have triggered its own new network call rather than \
                reusing the cancelled fetch's single call
                """
            )
        }
    }

    @Test(
        """
        evictAll() resumes every waiter still suspended in a coalescedFetch it is about to \
        tear down (with CancellationError) rather than silently dropping the in-flight entry \
        and leaving that waiter's continuation unresumed forever
        """
    )
    func evictAllResumesSuspendedFetchWaitersRatherThanHangingThem() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.hold(urls[0])
            await transport.enqueue(.success(successResult()), for: urls[0])

            let waiterTask = Task { try await service.asset(for: key) }
            await transport.waitForCallCount(1, for: urls[0])
            try await Task.sleep(nanoseconds: 20_000_000)

            // `evictAll()` itself never touches the transport, so it is
            // safe to call while the fetch is still held/pending: this is
            // exactly the moment a waiter is suspended inside
            // `coalescedFetch`'s `withCheckedContinuation`, the scenario
            // that must never hang.
            await service.evictAll()
            await transport.release(urls[0])

            // `Task.value`/`.result` alone would hang forever if this
            // waiter's continuation was never resumed; racing it against a
            // generous timeout turns that hang into a reported failure
            // instead of a stuck test process.
            let result = await withTaskGroup(
                of: Result<CachedAsset, Error>?.self,
                returning: Result<CachedAsset, Error>?.self
            ) { group in
                group.addTask { () -> Result<CachedAsset, Error>? in
                    await waiterTask.result
                }
                group.addTask { () -> Result<CachedAsset, Error>? in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return nil
                }
                let first: Result<CachedAsset, Error>?? = await group.next()
                group.cancelAll()
                return first ?? nil
            }
            guard let result else {
                Issue.record(
                    "evictAll() must resume every suspended waiter; this one hung instead"
                )
                return
            }
            #expect(throws: (any Error).self) { try result.get() }
            if case let .failure(error) = result {
                #expect(error is CancellationError, "Expected CancellationError, got \(error)")
            }
        }
    }
}
