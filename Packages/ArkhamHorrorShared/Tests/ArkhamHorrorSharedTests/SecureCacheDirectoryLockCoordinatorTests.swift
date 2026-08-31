@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves ``SecureCacheDirectoryLockCoordinator``'s bounded, FIFO,
/// cancellation-aware in-process serialization of
/// ``SecureCacheDirectory/acquireExclusiveLock()`` -- the fix for a review
/// finding that every call previously opened its own lock-file descriptor
/// and dispatched its own dedicated GCD poll worker, so sustained
/// in-process contention (many concurrently *queued* waiters, not merely
/// genuinely concurrent lock holders) grew both open file descriptors and
/// worker threads without bound.
@Suite("SecureCacheDirectory lock coordinator bounded contention")
struct SecureCacheDirectoryLockCoordinatorTests {
    private func withScratchDirectory(
        _ body: (_ directory: URL) async throws -> Void
    ) async throws {
        let directoryParent = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("LockCoordinatorScratch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryParent,
            withIntermediateDirectories: true
        )
        let directory = directoryParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    /// The number of currently open file descriptors for this process --
    /// see ``SecureCacheDirectoryPathWalkTests``' identically-named helper
    /// for why `/dev/fd` is used and why its result is only meaningful as
    /// a *before/after delta*, never an absolute count, given this suite
    /// runs alongside many unrelated concurrent tests.
    private func openFileDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1
    }

    @Test(
        """
        Sustained in-process contention for one instance's lock -- many concurrently \
        queued waiters, not merely genuinely concurrent holders -- never grows open file \
        descriptors beyond a small constant, regardless of how many waiters are queued
        """
    )
    func sustainedContentionDoesNotGrowDescriptors() async throws {
        try await withScratchDirectory { directory in
            let secure = try SecureCacheDirectory(directory: directory, fileManager: .default)
            let waiterCount = 64

            // Retry the whole measurement window a bounded number of
            // times purely to absorb noise from unrelated, concurrently
            // running sibling tests' own transient descriptor churn --
            // see ``SecureCacheDirectoryPathWalkTests``' identical
            // rationale. A genuine one-descriptor-per-waiter regression
            // here would reproduce a large (up to `waiterCount`), tightly
            // deterministic delta on every attempt; unrelated noise would
            // not.
            let tolerance = 20
            let maxAttempts = 5
            var lastBefore = -1
            var lastAfter = -1
            var sawAcceptableGrowth = false
            for attempt in 0 ..< maxAttempts {
                if attempt > 0 {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                _ = openFileDescriptorCount()
                let before = openFileDescriptorCount()

                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0 ..< waiterCount {
                        group.addTask {
                            try await secure.withExclusiveLock {}
                        }
                    }
                    try await group.waitForAll()
                }

                let after = openFileDescriptorCount()
                lastBefore = before
                lastAfter = after
                if before >= 0, after >= 0, after - before < tolerance {
                    sawAcceptableGrowth = true
                    break
                }
            }

            #expect(lastBefore >= 0)
            #expect(lastAfter >= 0)
            #expect(
                sawAcceptableGrowth,
                """
                Expected open descriptor count to stay roughly flat across \(waiterCount) \
                concurrently queued lock waiters (before: \(lastBefore), after: \(lastAfter)), \
                not grow by one descriptor per waiter
                """
            )
        }
    }

    @Test(
        """
        Concurrent in-process waiters for the same instance's lock are granted strict FIFO \
        order, not merely eventual, unordered access
        """
    )
    func waitersAreGrantedStrictFIFOOrder() async throws {
        try await withScratchDirectory { directory in
            let secure = try SecureCacheDirectory(directory: directory, fileManager: .default)
            let recorder = OrderRecorder()
            let waiterCount = 12

            // Hold the lock up front so every waiter below genuinely
            // queues rather than racing to be granted immediately.
            let blockerFD = try await secure.acquireExclusiveLock()

            // Rather than approximating submission order with a
            // `Task.sleep`-based stagger -- which only guarantees a
            // *minimum* delay, not an upper bound, and so can be
            // reordered by ordinary scheduler jitter under load (as
            // observed on constrained CI runners) -- this drives real,
            // provable call order: it spawns waiter `index + 1` only
            // after observing (via
            // ``SecureCacheDirectoryLockCoordinator/onWaiterPositionEstablished``)
            // that waiter `index`'s own call has already reached and
            // recorded its position in the real FIFO queue. This makes
            // submission order below identical to actual enqueue order,
            // with no dependency on timing whatsoever.
            let positionEstablished = AsyncStream<Void> { continuation in
                secure.lockCoordinator.onWaiterPositionEstablished = {
                    continuation.yield()
                }
            }
            var iterator = positionEstablished.makeAsyncIterator()

            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0 ..< waiterCount {
                    group.addTask {
                        try await secure.withExclusiveLock {
                            recorder.record(index)
                        }
                    }
                    _ = await iterator.next()
                }
                secure.releaseExclusiveLock(blockerFD)
                try await group.waitForAll()
            }

            #expect(recorder.order == Array(0 ..< waiterCount))
        }
    }

    @Test(
        """
        Cancelling one in-process caller queued waiting for the lock does not corrupt the \
        queue, does not cancel or otherwise disturb any other queued waiter, and the \
        cancelled caller never observes the lock as acquired
        """
    )
    func cancellingOneQueuedWaiterDoesNotDisturbOthers() async throws {
        try await withScratchDirectory { directory in
            let secure = try SecureCacheDirectory(directory: directory, fileManager: .default)
            let recorder = OrderRecorder()

            let blockerFD = try await secure.acquireExclusiveLock()

            // As in ``waitersAreGrantedStrictFIFOOrder()`` above, real
            // enqueue order is driven by observing each waiter's own
            // durably-established queue position -- never by a
            // `Task.sleep` stagger, which cannot itself prove order
            // under scheduler contention.
            let positionEstablished = AsyncStream<Void> { continuation in
                secure.lockCoordinator.onWaiterPositionEstablished = {
                    continuation.yield()
                }
            }
            var iterator = positionEstablished.makeAsyncIterator()

            // Two ordinary waiters bracketing one that will be cancelled
            // while still genuinely queued.
            let firstWaiter = Task {
                try await secure.withExclusiveLock { recorder.record(0) }
            }
            _ = await iterator.next()
            let toCancel = Task {
                _ = try await secure.withExclusiveLock {
                    Issue.record("A cancelled queued waiter must never run its critical section")
                }
            }
            _ = await iterator.next()
            let lastWaiter = Task {
                try await secure.withExclusiveLock { recorder.record(1) }
            }
            _ = await iterator.next()

            toCancel.cancel()

            var caughtCancellation = false
            do {
                try await toCancel.value
            } catch is CancellationError {
                caughtCancellation = true
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
            }
            #expect(caughtCancellation)

            secure.releaseExclusiveLock(blockerFD)

            try await firstWaiter.value
            try await lastWaiter.value

            #expect(recorder.order == [0, 1])

            // The lock itself must still be in a fully usable state after
            // a queued cancellation -- no stray hold, no corrupted queue
            // entry left behind.
            var ranAfterward = false
            try await secure.withExclusiveLock { ranAfterward = true }
            #expect(ranAfterward)
        }
    }

    @Test(
        """
        Exceeding the coordinator's bounded queued-waiter capacity fails the excess callers \
        closed with a typed error, rather than growing the in-process waiter queue without \
        bound
        """
    )
    func exceedingQueueCapacityFailsExcessCallersClosed() async throws {
        try await withScratchDirectory { directory in
            let secure = try SecureCacheDirectory(directory: directory, fileManager: .default)
            let cap = SecureCacheDirectoryLockCoordinator.maxQueuedWaiters
            let overflow = 20
            let totalContenders = cap + overflow

            let blockerFD = try await secure.acquireExclusiveLock()

            let successCount = Counter()
            let failureCount = Counter()

            // As above: wait for exactly `totalContenders` real enqueue
            // attempts to be durably recorded (success or immediate
            // over-capacity rejection, both of which fire the hook)
            // before releasing, rather than guessing a fixed sleep is
            // "long enough" for all of them to have even started under
            // load.
            let positionEstablished = AsyncStream<Void> { continuation in
                secure.lockCoordinator.onWaiterPositionEstablished = {
                    continuation.yield()
                }
            }
            var iterator = positionEstablished.makeAsyncIterator()

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0 ..< totalContenders {
                    group.addTask {
                        do {
                            try await secure.withExclusiveLock {}
                            successCount.increment()
                        } catch is AssetError {
                            failureCount.increment()
                        }
                    }
                }
                for _ in 0 ..< totalContenders {
                    _ = await iterator.next()
                }
                secure.releaseExclusiveLock(blockerFD)
                try await group.waitForAll()
            }

            #expect(successCount.value + failureCount.value == totalContenders)
            // Exactly `overflow` contenders arrive after the queue has
            // already reached its cap -- this is deterministic in count
            // (though not in *which* specific contenders are rejected),
            // since every enqueue attempt is itself serialized under one
            // lock.
            #expect(failureCount.value == overflow)
            #expect(successCount.value == cap)
        }
    }

    /// A small `os_unfair_lock`-guarded append-only order recorder,
    /// deliberately not a Swift actor: it must be touched from inside
    /// several plain, synchronous `withExclusiveLock` critical sections
    /// running on arbitrary threads, not from `async` contexts.
    private final class OrderRecorder: @unchecked Sendable {
        private var unfairLock = os_unfair_lock()
        private(set) var order: [Int] = []

        func record(_ index: Int) {
            os_unfair_lock_lock(&unfairLock)
            order.append(index)
            os_unfair_lock_unlock(&unfairLock)
        }
    }

    /// A small `os_unfair_lock`-guarded counter, for the same reason as
    /// ``OrderRecorder``.
    private final class Counter: @unchecked Sendable {
        private var unfairLock = os_unfair_lock()
        private var count = 0

        func increment() {
            os_unfair_lock_lock(&unfairLock)
            count += 1
            os_unfair_lock_unlock(&unfairLock)
        }

        var value: Int {
            os_unfair_lock_lock(&unfairLock)
            defer { os_unfair_lock_unlock(&unfairLock) }
            return count
        }
    }
}
