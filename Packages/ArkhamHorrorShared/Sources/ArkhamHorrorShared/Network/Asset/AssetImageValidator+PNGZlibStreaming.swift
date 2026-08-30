import Compression
import Foundation

// Exact zlib/DEFLATE inflation validation for a PNG's concatenated `IDAT`
// payload, beyond `validatePNGStructure(_:)`'s own container-level
// (chunk length/CRC/ordering) checks. Split out of
// `AssetImageValidator+PNGZlib.swift` (which owns the `IHDR`-derived
// exact-byte-count math this file's decoder enforces) purely to keep
// each file within this project's configured SwiftLint file-length
// limit.
//
// A corrupted `IDAT` payload can still be a perfectly well-formed PNG
// *container* -- correct chunk lengths, correct per-chunk CRC-32s (which
// only cover the compressed bytes as stored, and so cannot detect
// corruption of the compressed *stream itself* that happens to leave
// every chunk's own length/CRC unchanged) -- while decompressing to
// something other than the exact number of filtered scanline bytes its
// own `IHDR` dimensions require: too few (a truncated/corrupted DEFLATE
// block cut short partway through), or too many (extra bytes encoded
// past the image's own last scanline). ImageIO's own PNG decoder does not
// reliably reject either case outright -- it can silently decode however
// much valid filtered data actually exists and leave the remainder as
// whatever pixels its own row-reconstruction happens to produce, which is
// exactly the "repaired" leniency this validator exists to close before
// anything is cached. This decompresses the actual bytes via the same
// zlib-compatible (RFC 1950/1951) primitive `Compression.framework`
// exposes -- a proven platform primitive, not a hand-rolled inflater --
// and requires the decompressed byte count to match the `IHDR`-derived
// expectation *exactly*, the whole compressed payload to be consumed by
// the time decompression cleanly ends (no trailing garbage after a valid
// stream), and the trailing Adler-32 checksum RFC 1950 mandates to match
// the actual decompressed bytes.

/// Incremental RFC 1950 Adler-32 accumulator, matching the reference
/// algorithm's own periodic modulo-reduction cadence (`NMAX = 5552`)
/// exactly, so it can be fed one produced byte at a time across
/// arbitrarily many streamed-inflation iterations without ever
/// materializing the full decompressed image.
private struct Adler32Accumulator {
    private var sum1: UInt32 = 1
    private var sum2: UInt32 = 0
    private var countSinceReduction = 0
    private static let modAdler: UInt32 = 65521
    private static let nmax = 5552

    mutating func absorb(_ byte: UInt8) {
        sum1 += UInt32(byte)
        sum2 += sum1
        countSinceReduction += 1
        if countSinceReduction == Self.nmax {
            sum1 %= Self.modAdler
            sum2 %= Self.modAdler
            countSinceReduction = 0
        }
    }

    var value: UInt32 {
        let finalSum1 = sum1 % Self.modAdler
        let finalSum2 = sum2 % Self.modAdler
        return (finalSum2 << 16) | finalSum1
    }
}

extension AssetImageValidator {
    /// Validates RFC 1950's 2-byte zlib header (CMF/FLG): CM (low nibble of
    /// CMF) must be 8 (DEFLATE); the header checksum (`CMF*256 + FLG`) must
    /// be an exact multiple of 31; FDICT (bit 5 of FLG) must be unset --
    /// PNG never uses a preset dictionary, and this decoder never supplies
    /// one, so a stream that claims one can never decode correctly
    /// regardless.
    private static func validateZlibHeader(cmf: UInt8, flg: UInt8) throws {
        guard cmf & 0x0F == 8 else { throw AssetError.malformedImageData }
        guard (Int(cmf) * 256 + Int(flg)) % 31 == 0 else { throw AssetError.malformedImageData }
        guard flg & 0x20 == 0 else { throw AssetError.malformedImageData }
    }

    /// Reads the trailing big-endian Adler-32 checksum from the final 4
    /// bytes of a complete RFC 1950 zlib stream.
    private static func readTrailingAdler32(_ bytes: [UInt8]) -> UInt32 {
        (UInt32(bytes[bytes.count - 4]) << 24)
            | (UInt32(bytes[bytes.count - 3]) << 16)
            | (UInt32(bytes[bytes.count - 2]) << 8)
            | UInt32(bytes[bytes.count - 1])
    }

    /// Fixed per-iteration output-buffer capacity for streamed inflation.
    /// Bounded by ``pngRowByteCount(width:colorInfo:)``'s own maximum at
    /// this pipeline's configured `maxDimension` (8192): a single
    /// scanline can never exceed roughly 65 KiB, so reusing exactly one
    /// row's worth of scratch space per iteration -- rather than ever
    /// allocating a buffer sized to the full decompressed image, which
    /// can otherwise reach hundreds of megabytes at this pipeline's own
    /// configured pixel-count limit -- is sufficient for every image this
    /// validator ever accepts.
    private static let maximumStreamingRowByteCount = 8192 * 4 * 16 / 8 + 1

    /// Initializes a `compression_stream` decoding `deflateRange` of
    /// `inBase` into `scratchBase`, per RFC 1950/1951 (`COMPRESSION_ZLIB`).
    /// Split out of ``validateStreamedPNGInflation(_:deflateRange:rowByteCount:rowCount:)``
    /// purely to keep that function's own body/complexity within this
    /// project's configured `SwiftLint` limits -- callers must still
    /// `defer { compression_stream_destroy(&stream) }` themselves.
    private static func makeInflateStream(
        inBase: UnsafePointer<UInt8>,
        deflateRange: Range<Int>,
        scratchBase: UnsafeMutablePointer<UInt8>
    ) throws -> compression_stream {
        var stream = compression_stream(
            dst_ptr: scratchBase,
            dst_size: 0,
            src_ptr: inBase + deflateRange.lowerBound,
            src_size: deflateRange.count,
            state: nil
        )
        // `compression_stream_init` resets every field to zero except
        // `state`, so the buffer pointers/sizes above must be
        // (re-)assigned only *after* this call, not before it.
        guard compression_stream_init(
            &stream,
            COMPRESSION_STREAM_DECODE,
            COMPRESSION_ZLIB
        ) == COMPRESSION_STATUS_OK else {
            throw AssetError.malformedImageData
        }
        stream.src_ptr = inBase + deflateRange.lowerBound
        stream.src_size = deflateRange.count
        return stream
    }

    /// Validates every produced byte's leading-filter-type constraint (at
    /// each scanline boundary) and folds it into `accumulator`'s running
    /// Adler-32. Split out of
    /// ``validateStreamedPNGInflation(_:deflateRange:rowByteCount:rowCount:)``
    /// purely to keep that function's own body/complexity within this
    /// project's configured `SwiftLint` limits.
    private static func absorbProducedChunk(
        _ scratchBuffer: UnsafeMutableBufferPointer<UInt8>,
        produced: Int,
        producedTotalBefore: Int,
        rowByteCount: Int,
        accumulator: inout Adler32Accumulator
    ) throws {
        for index in 0 ..< produced {
            let absolutePosition = producedTotalBefore + index
            if absolutePosition % rowByteCount == 0 {
                guard scratchBuffer[index] <= 4 else {
                    throw AssetError.malformedImageData
                }
            }
            accumulator.absorb(scratchBuffer[index])
        }
    }

    /// The fixed per-scanline byte count and the resulting exact total
    /// expected decompressed byte count, bundled together purely to keep
    /// ``runInflationLoop(stream:scratchBuffer:scratchBase:budget:accumulator:)``'s
    /// own parameter count within this project's configured `SwiftLint`
    /// limits.
    private struct PNGScanlineBudget {
        let rowByteCount: Int
        let expectedTotal: Int
    }

    /// Runs the fixed-size streamed inflation loop to completion: repeatedly
    /// calling `compression_stream_process`, bounding the running produced
    /// total against `budget.expectedTotal`, and folding every produced byte
    /// into `accumulator` via
    /// ``absorbProducedChunk(_:produced:producedTotalBefore:rowByteCount:accumulator:)``.
    /// Split out of ``validateStreamedPNGInflation(_:deflateRange:rowByteCount:rowCount:)``
    /// purely to keep that function's own body/complexity within this
    /// project's configured `SwiftLint` limits. Requires a clean
    /// end-of-stream that consumes every last byte of the input range.
    private static func runInflationLoop(
        stream: inout compression_stream,
        scratchBuffer: UnsafeMutableBufferPointer<UInt8>,
        scratchBase: UnsafeMutablePointer<UInt8>,
        budget: PNGScanlineBudget,
        accumulator: inout Adler32Accumulator
    ) throws -> Int {
        var producedTotal = 0
        var reachedEnd = false
        while !reachedEnd {
            stream.dst_ptr = scratchBase
            stream.dst_size = scratchBuffer.count
            let status = compression_stream_process(
                &stream,
                Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            )
            guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                throw AssetError.malformedImageData
            }
            let produced = scratchBuffer.count - stream.dst_size
            if produced > 0 {
                let (newTotal, producedOverflowed) =
                    producedTotal.addingReportingOverflow(produced)
                guard !producedOverflowed, newTotal <= budget.expectedTotal else {
                    throw AssetError.malformedImageData
                }
                try absorbProducedChunk(
                    scratchBuffer,
                    produced: produced,
                    producedTotalBefore: producedTotal,
                    rowByteCount: budget.rowByteCount,
                    accumulator: &accumulator
                )
                producedTotal = newTotal
            }
            if status == COMPRESSION_STATUS_END {
                reachedEnd = true
            }
        }
        guard stream.src_size == 0 else {
            throw AssetError.malformedImageData
        }
        return producedTotal
    }

    /// Streams `bytes[deflateRange]` through a fixed-size, single-row
    /// scratch buffer, incrementally: validating that every scanline's
    /// leading filter-type byte is one of the five values the PNG
    /// specification defines (`0`–`4`), accumulating the running Adler-32
    /// checksum, and bounding the total produced byte count against
    /// `rowByteCount * rowCount` -- all without ever retaining or copying
    /// the full inflated image. Requires a clean end-of-stream that
    /// consumes every last byte of `deflateRange` (no trailing garbage
    /// after a valid, complete zlib stream) and an exact total byte-count
    /// match (no more, no fewer, than `rowByteCount * rowCount`).
    private static func validateStreamedPNGInflation(
        _ bytes: [UInt8],
        deflateRange: Range<Int>,
        rowByteCount: Int,
        rowCount: Int
    ) throws -> UInt32 {
        guard
            rowByteCount > 0,
            rowByteCount <= maximumStreamingRowByteCount,
            rowCount > 0
        else {
            throw AssetError.malformedImageData
        }
        let (expectedTotal, totalOverflowed) = rowByteCount.multipliedReportingOverflow(
            by: rowCount
        )
        guard !totalOverflowed else { throw AssetError.malformedImageData }

        var scratch = [UInt8](repeating: 0, count: rowByteCount)
        var accumulator = Adler32Accumulator()
        var producedTotal = 0

        try scratch.withUnsafeMutableBufferPointer { scratchBuffer in
            try bytes.withUnsafeBufferPointer { inBuffer in
                guard
                    let inBase = inBuffer.baseAddress,
                    let scratchBase = scratchBuffer.baseAddress
                else {
                    throw AssetError.malformedImageData
                }
                var stream = try makeInflateStream(
                    inBase: inBase,
                    deflateRange: deflateRange,
                    scratchBase: scratchBase
                )
                defer { compression_stream_destroy(&stream) }
                producedTotal = try runInflationLoop(
                    stream: &stream,
                    scratchBuffer: scratchBuffer,
                    scratchBase: scratchBase,
                    budget: PNGScanlineBudget(
                        rowByteCount: rowByteCount,
                        expectedTotal: expectedTotal
                    ),
                    accumulator: &accumulator
                )
            }
        }
        guard producedTotal == expectedTotal else {
            throw AssetError.malformedImageData
        }
        return accumulator.value
    }

    /// Decompresses `idatPayload` (the exact concatenated bytes of every
    /// `IDAT` chunk, a single RFC 1950 zlib datastream per the PNG
    /// specification) and requires the result to match
    /// `rowByteCount * rowCount` exactly, with the entire payload
    /// consumed, every scanline's leading filter byte valid, and its
    /// trailing Adler-32 checksum verified -- streamed through a
    /// fixed-size, single-row scratch buffer rather than ever
    /// materializing the full decompressed image (see
    /// ``validateStreamedPNGInflation(_:deflateRange:rowByteCount:rowCount:)``).
    static func validateExactPNGInflation(
        idatPayload: Data,
        rowByteCount: Int,
        rowCount: Int
    ) throws {
        // 2-byte zlib header (CMF/FLG) + at least 0 bytes of DEFLATE data
        // + 4-byte Adler-32 trailer, at minimum.
        guard idatPayload.count >= 6, rowByteCount > 0, rowCount > 0 else {
            throw AssetError.malformedImageData
        }
        let bytes = [UInt8](idatPayload)
        try validateZlibHeader(cmf: bytes[0], flg: bytes[1])

        let deflateRange = 2 ..< (bytes.count - 4)
        guard deflateRange.lowerBound <= deflateRange.upperBound else {
            throw AssetError.malformedImageData
        }
        let storedAdler32 = readTrailingAdler32(bytes)

        let actualAdler32 = try validateStreamedPNGInflation(
            bytes,
            deflateRange: deflateRange,
            rowByteCount: rowByteCount,
            rowCount: rowCount
        )
        guard actualAdler32 == storedAdler32 else {
            throw AssetError.malformedImageData
        }
    }
}
