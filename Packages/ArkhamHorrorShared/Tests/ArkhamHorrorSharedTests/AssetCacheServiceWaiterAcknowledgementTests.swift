@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of a cumulative review's finding: a
/// coalesced fetch/revalidation's completion watcher
/// (``AssetCacheService/completeFetch(_:fetchID:result:)``/
/// ``AssetCacheService/completeRevalidation(_:fetchID:result:)``) used to
/// clear its `inFlight`/`inFlightRevalidation` entry and resume every
/// waiter *before* any of those waiters had a chance to acknowledge
/// delivery. When a waiter's own task was cancelled concurrently with (or
/// immediately after) that exact completion — rather than while the
/// underlying work was still genuinely pending — the completion watcher
/// had already erased the only bookkeeping
/// ``AssetCacheService/cancelWaiter(_:fetchID:waiterID:)``/
/// ``AssetCacheService/cancelRevalidationWaiter(_:fetchID:waiterID:)``
/// consult to decide whether a retraction is owed: that cancellation
/// handler found nothing left to act on, the cancelled caller still
/// correctly observed `CancellationError`, but the mutation the shared
/// operation had just applied was never retracted — left fully readable
/// to any later, unrelated caller even though the sole caller who asked
/// for it never actually received it.
///
/// `AssetCacheService/testOnlyBeforeFetchResumesWaiters`/
/// `testOnlyBeforeRevalidationResumesWaiters` exist purely to
/// let these two tests reproduce that exact interleaving
/// deterministically: the hook fires synchronously, from inside the
/// completion watcher, strictly *before* any waiter's continuation is
/// resumed — cancelling the sole waiter's own task from inside the hook
/// therefore happens-before that waiter's continuation ever resumes,
/// with no dependence on incidental actor-scheduling timing.
extension AssetCacheServiceTests {
    @Test(
        """
        A sole waiter whose own task is cancelled at the exact moment the shared fetch it was \
        attached to already completed successfully must still have that fetch's mutation \
        retracted -- never left servable to a later caller purely because nobody survived to \
        actually receive it
        """
    )
    func soleWaiterCancelledExactlyAtFetchCompletionStillRetractsMutation() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.hold(urls[0])
            await transport.enqueue(.success(successResult()), for: urls[0])

            let onlyTask = Task { try await service.asset(for: key) }
            await transport.waitForCallCount(1, for: urls[0])
            try await waitForInFlightWaiterCount(1, for: key, on: service)

            // Fires synchronously, inside `completeFetch`, strictly
            // before this sole waiter's continuation resumes -- so this
            // cancellation is guaranteed to have already landed by the
            // time this waiter's own body checks `Task.isCancelled`.
            await service.installTestOnlyBeforeFetchResumesWaiters {
                onlyTask.cancel()
            }
            await transport.release(urls[0])

            let result = await onlyTask.result
            #expect(throws: (any Error).self) { try result.get() }
            if case let .failure(error) = result {
                #expect(error is CancellationError, "Expected CancellationError, got \(error)")
            }

            // A later, independent request must perform its own fresh
            // network fetch: the abandoned fetch's mutation must have
            // been retracted, never silently left behind for this
            // request to be served from instead.
            await transport.enqueue(.success(successResult()), for: urls[0])
            let secondAttempt = try await service.asset(for: key)
            #expect(secondAttempt.payload == AssetImageFixtureBuilder.validAVIF(
                width: 4,
                height: 4
            ))
            let callCount = await transport.callCount(for: urls[0])
            #expect(
                callCount == 2,
                """
                The abandoned fetch must never have left a cache entry the second attempt \
                could have been served from instead of hitting the network again
                """
            )
        }
    }

    @Test(
        """
        A sole waiter whose own task is cancelled at the exact moment a shared revalidation it \
        was attached to already published a fresh 200 must still have that revalidation's \
        mutation retracted -- never left servable to a later caller purely because nobody \
        survived to actually receive it
        """
    )
    func soleWaiterCancelledExactlyAtRevalidationCompletionStillRetractsMutation() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)

            let seedBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            await transport.enqueue(
                .success(successResult(body: seedBody, etag: "\"v1\"")),
                for: urls[0]
            )
            let seeded = try await service.asset(for: key)
            #expect(seeded.payload == seedBody)

            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 5, height: 5)
            await transport.hold(urls[0])
            await transport.enqueue(
                .success(successResult(body: freshBody, etag: "\"v2\"")),
                for: urls[0]
            )

            let onlyTask = Task { try await service.revalidate(for: key) }
            await transport.waitForCallCount(2, for: urls[0])
            try await waitForInFlightRevalidationWaiterCount(1, for: key, on: service)

            await service.installTestOnlyBeforeRevalidationResumesWaiters {
                onlyTask.cancel()
            }
            await transport.release(urls[0])

            let result = await onlyTask.result
            #expect(throws: (any Error).self) { try result.get() }
            if case let .failure(error) = result {
                #expect(error is CancellationError, "Expected CancellationError, got \(error)")
            }

            // Neither the old (`seedBody`) nor the abandoned new
            // (`freshBody`) content may remain trustworthy: the
            // abandoned revalidation's own token superseded the old
            // entry's, so a later request must perform a genuine fresh,
            // unconditional fetch rather than being served either body.
            let finalBody = AssetImageFixtureBuilder.validAVIF(width: 6, height: 6)
            await transport.enqueue(.success(successResult(body: finalBody)), for: urls[0])
            let resolved = try await service.asset(for: key)
            #expect(resolved.payload == finalBody)
            let callCount = await transport.callCount(for: urls[0])
            #expect(
                callCount == 3,
                "Expected seed fetch + abandoned revalidation + final fresh fetch"
            )
        }
    }
}
