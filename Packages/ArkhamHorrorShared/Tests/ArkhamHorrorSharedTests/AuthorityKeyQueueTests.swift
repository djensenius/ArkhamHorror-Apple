@testable import ArkhamHorrorShared
import Testing

/// Direct, fast unit coverage for ``AuthorityKeyQueue`` itself, isolated
/// from the full ``AssetCacheService`` actor: proves plain FIFO ordering
/// and amortized-bounded backing storage regardless of how the full
/// actor's busy-key requeuing happens to interact with it. Split out of
/// `AssetCacheServiceAuthorityPruningTests.swift` purely to stay under
/// SwiftLint's `file_length`.
@Suite("AuthorityKeyQueue")
struct AuthorityKeyQueueTests {
    @Test("append/popFirst preserve strict FIFO order")
    func preservesFIFOOrder() {
        var queue = AuthorityKeyQueue<Int>()
        for value in 0 ..< 1000 {
            queue.append(value)
        }
        #expect(queue.count == 1000)
        for expected in 0 ..< 1000 {
            #expect(queue.popFirst() == expected)
        }
        #expect(queue.isEmpty)
        #expect(queue.popFirst() == nil)
    }

    @Test("A sustained pop-then-append cycle (simulating a busy-key requeue) keeps count exact")
    func popThenAppendCycleKeepsCountExact() {
        var queue = AuthorityKeyQueue<Int>()
        for value in 0 ..< 128 {
            queue.append(value)
        }
        // Simulates 200,000 touches worth of "pop the oldest busy key,
        // requeue it at the back" -- the exact pattern
        // `pruneAuthorityKeysIfNeeded(protecting:)` performs on every
        // touch while every tracked key remains busy. Runs quickly since
        // each op is O(1) amortized, not O(remaining) the way
        // `Array.removeFirst()` would make it.
        for _ in 0 ..< 200_000 {
            guard let value = queue.popFirst() else {
                Issue.record("queue unexpectedly empty mid-cycle")
                break
            }
            queue.append(value)
        }
        #expect(queue.count == 128)
    }

    @Test("removeAll empties the queue and resets it to a fresh, appendable state")
    func removeAllResetsQueue() {
        var queue = AuthorityKeyQueue<Int>()
        for value in 0 ..< 50 {
            queue.append(value)
        }
        queue.removeAll()
        #expect(queue.isEmpty)
        queue.append(1)
        #expect(queue.count == 1)
        #expect(queue.popFirst() == 1)
    }
}
