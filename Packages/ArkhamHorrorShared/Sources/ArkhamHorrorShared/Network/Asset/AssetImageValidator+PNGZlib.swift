import Compression
import Foundation

/// Exact zlib/DEFLATE inflation validation for a PNG's concatenated `IDAT`
/// payload, beyond ``validatePNGStructure(_:)``'s own container-level
/// (chunk length/CRC/ordering) checks.
///
/// A corrupted `IDAT` payload can still be a perfectly well-formed PNG
/// *container* -- correct chunk lengths, correct per-chunk CRC-32s (which
/// only cover the compressed bytes as stored, and so cannot detect
/// corruption of the compressed *stream itself* that happens to leave
/// every chunk's own length/CRC unchanged) -- while decompressing to
/// something other than the exact number of filtered scanline bytes its
/// own `IHDR` dimensions require: too few (a truncated/corrupted DEFLATE
/// block cut short partway through), or too many (extra bytes encoded
/// past the image's own last scanline). ImageIO's own PNG decoder does not
/// reliably reject either case outright -- it can silently decode however
/// much valid filtered data actually exists and leave the remainder as
/// whatever pixels its own row-reconstruction happens to produce, which is
/// exactly the "repaired" leniency this validator exists to close before
/// anything is cached. This decompresses the actual bytes via the same
/// zlib-compatible (RFC 1950/1951) primitive `Compression.framework`
/// exposes -- a proven platform primitive, not a hand-rolled inflater --
/// and requires the decompressed byte count to match the `IHDR`-derived
/// expectation *exactly*, the whole compressed payload to be consumed by
/// the time decompression cleanly ends (no trailing garbage after a valid
/// stream), and the trailing Adler-32 checksum RFC 1950 mandates to match
/// the actual decompressed bytes.
extension AssetImageValidator {
    /// The subset of `IHDR` fields needed to compute the exact expected
    /// decompressed (filtered scanline) byte count, beyond the
    /// width/height ``parsePNGDimensions(_:)`` already extracts.
    struct PNGColorInfo: Equatable {
        let bitDepth: UInt8
        let colorType: UInt8
        let interlaceMethod: UInt8
    }

    /// Reads the bit-depth, color-type, and interlace-method fields from
    /// a PNG's `IHDR` chunk. Only ever called after ``parsePNGDimensions(_:)``
    /// has already confirmed `data` is at least 33 bytes with a
    /// well-formed, 13-byte `IHDR` chunk at the expected fixed offset, so
    /// the same fixed byte offsets are safe to read directly here.
    static func parsePNGColorInfo(_ data: Data) throws -> PNGColorInfo {
        guard data.count >= 29 else { throw AssetError.malformedImageData }
        let base = data.startIndex
        return PNGColorInfo(
            bitDepth: data[base + 24],
            colorType: data[base + 25],
            interlaceMethod: data[base + 28]
        )
    }

    /// The exact number of decompressed (filtered scanline) bytes a
    /// non-interlaced PNG with the given dimensions and color info must
    /// decompress to: one filter-type byte plus
    /// `ceil(width * channels * bitDepth / 8)` bytes of actual pixel data,
    /// per scanline, for `height` scanlines. Adam7-interlaced PNGs
    /// (`interlaceMethod != 0`) split their data across seven differently
    /// sized sub-images and are deliberately rejected as unsupported
    /// rather than exactly validated -- ImageIO-generated fixtures (this
    /// pipeline's own fixture builder, and every real asset this cache
    /// expects) never use interlacing, and getting Adam7's per-pass
    /// dimension arithmetic wrong would be worse than simply not
    /// supporting it.
    /// Maps an `IHDR` color-type byte to its channel count, throwing for
    /// any value outside the five PNG-specification-defined color types.
    private static func pngChannelCount(for colorType: UInt8) throws -> Int {
        switch colorType {
        case 0: return 1 // grayscale
        case 2: return 3 // truecolor
        case 3: return 1 // indexed
        case 4: return 2 // grayscale + alpha
        case 6: return 4 // truecolor + alpha
        default: throw AssetError.malformedImageData
        }
    }

    static func expectedPNGScanlineByteCount(
        width: Int,
        height: Int,
        colorInfo: PNGColorInfo
    ) throws -> Int {
        guard colorInfo.interlaceMethod == 0 else {
            throw AssetError.malformedImageData
        }
        let channels = try pngChannelCount(for: colorInfo.colorType)
        guard [1, 2, 4, 8, 16].contains(colorInfo.bitDepth) else {
            throw AssetError.malformedImageData
        }
        let bitsPerPixel = channels * Int(colorInfo.bitDepth)
        let (bitsPerRow, bitsOverflowed) = width.multipliedReportingOverflow(by: bitsPerPixel)
        guard !bitsOverflowed else { throw AssetError.malformedImageData }
        let bytesPerScanline = (bitsPerRow + 7) / 8
        let (rowLength, rowOverflowed) = bytesPerScanline.addingReportingOverflow(1)
        guard !rowOverflowed else { throw AssetError.malformedImageData }
        let (total, totalOverflowed) = rowLength.multipliedReportingOverflow(by: height)
        guard !totalOverflowed else { throw AssetError.malformedImageData }
        return total
    }

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

    /// Decompresses `bytes[deflateRange]` into a fixed `capacity + 1`-byte
    /// buffer (one byte larger than the expected output, so a stream that
    /// decompresses to more than expected fills it completely without ever
    /// reaching a clean end -- distinguishable from the exact-match case)
    /// and returns exactly the bytes actually produced. Requires a clean
    /// end-of-stream that also consumed every last byte of `deflateRange`
    /// (no trailing garbage after a valid, complete zlib stream, never
    /// legitimate in a PNG `IDAT` concatenation).
    private static func inflate(
        _ bytes: [UInt8],
        deflateRange: Range<Int>,
        capacity: Int
    ) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: capacity + 1)
        let producedByteCount = try output.withUnsafeMutableBufferPointer { outBuffer -> Int in
            try bytes.withUnsafeBufferPointer { inBuffer -> Int in
                guard let outBase = outBuffer.baseAddress, let inBase = inBuffer.baseAddress else {
                    throw AssetError.malformedImageData
                }
                var stream = compression_stream(
                    dst_ptr: outBase,
                    dst_size: outBuffer.count,
                    src_ptr: inBase + deflateRange.lowerBound,
                    src_size: deflateRange.count,
                    state: nil
                )
                // `compression_stream_init` resets every field to zero
                // except `state`, so the buffer pointers/sizes above must
                // be (re-)assigned only *after* this call, not before it.
                guard compression_stream_init(
                    &stream,
                    COMPRESSION_STREAM_DECODE,
                    COMPRESSION_ZLIB
                ) == COMPRESSION_STATUS_OK else {
                    throw AssetError.malformedImageData
                }
                defer { compression_stream_destroy(&stream) }
                stream.dst_ptr = outBase
                stream.dst_size = outBuffer.count
                stream.src_ptr = inBase + deflateRange.lowerBound
                stream.src_size = deflateRange.count

                let status = compression_stream_process(
                    &stream,
                    Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                guard status == COMPRESSION_STATUS_END else {
                    throw AssetError.malformedImageData
                }
                guard stream.src_size == 0 else {
                    throw AssetError.malformedImageData
                }
                return outBuffer.count - stream.dst_size
            }
        }
        return Array(output.prefix(producedByteCount))
    }

    /// Decompresses `idatPayload` (the exact concatenated bytes of every
    /// `IDAT` chunk, a single RFC 1950 zlib datastream per the PNG
    /// specification) and requires the result to match `expectedByteCount`
    /// exactly, with the entire payload consumed and its trailing
    /// Adler-32 checksum verified.
    static func validateExactPNGInflation(idatPayload: Data, expectedByteCount: Int) throws {
        // 2-byte zlib header (CMF/FLG) + at least 0 bytes of DEFLATE data
        // + 4-byte Adler-32 trailer, at minimum.
        guard idatPayload.count >= 6, expectedByteCount > 0 else {
            throw AssetError.malformedImageData
        }
        let bytes = [UInt8](idatPayload)
        try validateZlibHeader(cmf: bytes[0], flg: bytes[1])

        let deflateRange = 2 ..< (bytes.count - 4)
        guard deflateRange.lowerBound <= deflateRange.upperBound else {
            throw AssetError.malformedImageData
        }
        let storedAdler32 = readTrailingAdler32(bytes)

        // Bounded by the same already-`validateDimensions`-checked pixel
        // count this payload's own declared width/height/limits already
        // constrain -- no larger, in the worst case, than the eager
        // pixel-decode bitmap `AssetImageDecoder` already allocates.
        let decompressed = try inflate(
            bytes,
            deflateRange: deflateRange,
            capacity: expectedByteCount
        )

        guard decompressed.count == expectedByteCount else {
            throw AssetError.malformedImageData
        }
        let actualAdler32 = adler32(decompressed)
        guard actualAdler32 == storedAdler32 else {
            throw AssetError.malformedImageData
        }
    }

    /// RFC 1950's Adler-32 checksum, computed with the standard `NMAX`
    /// batched-modulo optimization (deferring the modulo reduction every
    /// 5552 bytes, the most bytes that can accumulate in a 32-bit
    /// accumulator without overflow) rather than a naive per-byte modulo,
    /// since this may run over a decompressed buffer as large as this
    /// pipeline's own configured pixel-count limit allows.
    private static func adler32(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var sum1: UInt32 = 1
        var sum2: UInt32 = 0
        let modAdler: UInt32 = 65521
        let nmax = 5552
        var countSinceReduction = 0
        for byte in bytes {
            sum1 += UInt32(byte)
            sum2 += sum1
            countSinceReduction += 1
            if countSinceReduction == nmax {
                sum1 %= modAdler
                sum2 %= modAdler
                countSinceReduction = 0
            }
        }
        sum1 %= modAdler
        sum2 %= modAdler
        return (sum2 << 16) | sum1
    }
}
