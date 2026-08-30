@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("AssetByteCapReader")
struct AssetByteCapReaderTests {
    private let limits = AssetCacheLimits(
        maxEncodedBytes: 100,
        maxDimension: 8192,
        maxPixelCount: 32_000_000,
        memoryBudgetBytes: 1024,
        diskBudgetBytes: 1024
    )

    private func stream(byteCount: Int) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for index in 0 ..< byteCount {
                continuation.yield(UInt8(index % 256))
            }
            continuation.finish()
        }
    }

    @Test("A body exactly at the cap is accepted")
    func exactlyAtCapAccepted() async throws {
        let data = try await AssetByteCapReader.read(stream(byteCount: 100), limits: limits)
        #expect(data.count == 100)
    }

    @Test("A body one byte over the cap is rejected")
    func oneByteOverCapRejected() async throws {
        await #expect(throws: AssetError.responseTooLarge) {
            _ = try await AssetByteCapReader.read(self.stream(byteCount: 101), limits: self.limits)
        }
    }

    @Test(
        "A body far larger than the cap is rejected without buffering all of it (incremental)"
    )
    func farOverCapRejectedIncrementally() async throws {
        // Larger than the reader's internal 64 KiB chunk boundary, so this
        // specifically exercises the "reject mid-stream, at the first
        // buffered chunk" path rather than only the final trailing-partial
        // check.
        await #expect(throws: AssetError.responseTooLarge) {
            _ = try await AssetByteCapReader.read(
                self.stream(byteCount: 200_000),
                limits: self.limits
            )
        }
    }

    @Test(
        """
        A cap exceeded mid-chunk is rejected immediately, without buffering another \
        full chunk past it
        """
    )
    func capExceededRejectedBeforeNextChunkBoundary() async throws {
        // A cap smaller than the reader's internal 64 KiB chunk size: if
        // the incremental check only ran at each chunk-flush boundary
        // (rather than on every byte), this could buffer up to an entire
        // extra chunk beyond the cap before ever noticing. A counting
        // sequence records exactly how many bytes were pulled before the
        // reader throws, so this asserts that bound directly rather than
        // only asserting "it eventually throws".
        let tinyLimits = AssetCacheLimits(
            maxEncodedBytes: 10,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1024,
            diskBudgetBytes: 1024
        )
        let counter = ByteConsumptionCounter()
        await #expect(throws: AssetError.responseTooLarge) {
            _ = try await AssetByteCapReader.read(
                CountingByteSequence(totalByteCount: 200_000, counter: counter),
                limits: tinyLimits
            )
        }
        let consumed = await counter.count
        #expect(
            consumed <= 11,
            """
            Expected the reader to stop within one byte of the 10-byte cap, not after \
            buffering a further 64 KiB chunk (consumed \(consumed) bytes)
            """
        )
    }

    @Test("An empty body is accepted")
    func emptyBodyAccepted() async throws {
        let data = try await AssetByteCapReader.read(stream(byteCount: 0), limits: limits)
        #expect(data.isEmpty)
    }

    @Test("Cancelling the reading task propagates cancellation rather than returning partial data")
    func cancellationPropagates() async throws {
        // `Task.sleep` inside `next()` genuinely participates in the
        // *consuming* task's cooperative cancellation (unlike a detached
        // producer `Task` feeding an `AsyncStream`, which would not observe
        // `readTask`'s cancellation at all), so this exercises the same
        // cancellation path a real slow network read would.
        let readTask = Task {
            try await AssetByteCapReader.read(SlowByteSequence(), limits: limits)
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        readTask.cancel()
        let result = await readTask.result
        #expect(throws: CancellationError.self) {
            try result.get()
        }
    }
}

/// A byte sequence whose `next()` genuinely awaits `Task.sleep`, so that
/// cancelling the *consuming* task's cooperative cancellation is observed
/// mid-iteration (unlike a detached producer `Task` feeding an
/// `AsyncStream`, which would not observe the consumer's cancellation).
/// Declared at file scope (rather than nested inside the test function) so
/// its own `AsyncIterator` does not exceed SwiftLint's one-level nesting
/// limit.
private struct SlowByteSequence: AsyncSequence {
    struct AsyncIterator: AsyncIteratorProtocol {
        var counter: UInt8 = 0
        mutating func next() async throws -> UInt8? {
            try await Task.sleep(nanoseconds: 1_000_000)
            defer { counter = counter &+ 1 }
            return counter
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator()
    }
}

/// Actor-isolated counter recording how many bytes ``CountingByteSequence``
/// has yielded, so a test can assert exactly how far ``AssetByteCapReader``
/// read before rejecting an oversized body — not merely that it eventually
/// rejected it.
private actor ByteConsumptionCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

/// A byte sequence that records each byte it yields into `counter`, so a
/// test can measure exactly how many bytes a consumer pulled before
/// stopping (e.g. due to a reader throwing partway through), rather than
/// only observing the consumer's final outcome.
private struct CountingByteSequence: AsyncSequence {
    let totalByteCount: Int
    let counter: ByteConsumptionCounter

    struct AsyncIterator: AsyncIteratorProtocol {
        let totalByteCount: Int
        let counter: ByteConsumptionCounter
        var index = 0

        mutating func next() async throws -> UInt8? {
            guard index < totalByteCount else { return nil }
            defer { index += 1 }
            await counter.increment()
            return UInt8(index % 256)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(totalByteCount: totalByteCount, counter: counter)
    }
}
