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
        #expect(throws: (any Error).self) {
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
