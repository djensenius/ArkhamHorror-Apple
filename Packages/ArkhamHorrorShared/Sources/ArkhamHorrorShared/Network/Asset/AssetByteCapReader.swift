import Foundation

/// Reads a byte sequence incrementally, enforcing
/// ``AssetCacheLimits/maxEncodedBytes`` after every buffered chunk so an
/// oversized body is rejected while it is still arriving rather than after
/// buffering it in full.
///
/// Generic over `AsyncSequence` (rather than concretely
/// `URLSession.AsyncBytes`) purely so tests can exercise the exact cap
/// boundary with a synthetic `AsyncStream<UInt8>`, without any real
/// networking.
enum AssetByteCapReader {
    static func read<S: AsyncSequence>(
        _ bytes: S,
        limits: AssetCacheLimits
    ) async throws -> Data where S.Element == UInt8 {
        var data = Data()
        var buffer = [UInt8]()
        buffer.reserveCapacity(64 * 1024)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == buffer.capacity {
                data.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if data.count > limits.maxEncodedBytes {
                    throw AssetError.responseTooLarge
                }
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
