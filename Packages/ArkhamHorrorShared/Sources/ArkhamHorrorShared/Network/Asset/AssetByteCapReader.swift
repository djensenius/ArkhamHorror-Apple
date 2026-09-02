import Foundation

/// Reads a byte sequence incrementally, enforcing
/// ``AssetCacheLimits/maxEncodedBytes`` after every single byte arrives
/// (not merely at each buffered-chunk boundary) so an oversized body is
/// rejected the instant it exceeds the cap rather than after buffering an
/// extra chunk, or the full body, past it.
///
/// Generic over `AsyncSequence` (rather than concretely
/// `URLSession.AsyncBytes`) purely so tests can exercise the exact cap
/// boundary with a synthetic `AsyncStream<UInt8>`, without any real
/// networking.
enum AssetByteCapReader {
    /// The number of bytes buffered before each incremental flush into
    /// `data`. Compared against a fixed constant rather than
    /// `buffer.capacity`, since `Array.capacity` is an implementation
    /// detail that can grow past the value passed to `reserveCapacity`,
    /// which would delay (or with the wrong comparison, silently skip) the
    /// incremental `maxEncodedBytes` check.
    private static let chunkSize = 64 * 1024

    static func read<S: AsyncSequence>(
        _ bytes: S,
        limits: AssetCacheLimits
    ) async throws -> Data where S.Element == UInt8 {
        var data = Data()
        var buffer = [UInt8]()
        buffer.reserveCapacity(chunkSize)
        // Incremented by exactly one per yielded byte (rather than
        // recomputed as `data.count + buffer.count` on every single byte)
        // so the incremental cap check stays O(1) per byte instead of
        // re-deriving the same running total from two other counters on
        // every iteration; it always equals `data.count + buffer.count`.
        var runningTotal = 0

        for try await byte in bytes {
            buffer.append(byte)
            // Checked on every byte (not only at each `chunkSize` flush
            // boundary), overflow-safely, so a small configured cap is
            // enforced the instant it is exceeded rather than allowing up
            // to an extra `chunkSize` bytes to buffer first.
            let (incremented, overflowed) = runningTotal.addingReportingOverflow(1)
            runningTotal = incremented
            if overflowed || runningTotal > limits.maxEncodedBytes {
                throw AssetError.responseTooLarge
            }
            if buffer.count >= chunkSize {
                data.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            data.append(contentsOf: buffer)
        }
        if data.count > limits.maxEncodedBytes {
            throw AssetError.responseTooLarge
        }
        return data
    }
}
