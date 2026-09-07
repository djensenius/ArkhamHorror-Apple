@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for the streamed PNG zlib-inflation validator
/// (`AssetImageValidator+PNGZlib.swift`'s `validateStreamedPNGInflation`):
/// its mandatory-empty-`IEND` enforcement, its per-scanline filter-byte
/// check, and its ability to validate a payload whose *decompressed* size
/// would previously have required allocating (and copying) hundreds of
/// megabytes in one shot.
///
/// Unlike the other PNG fixtures in this package (which are always
/// produced by ImageIO, and so always carry a real DEFLATE-compressed
/// `IDAT` stream this suite cannot hand-tamper at the raw pixel/filter
/// level), these tests hand-build minimal, byte-exact PNGs whose `IDAT`
/// payload is an *uncompressed* ("stored") RFC 1951 DEFLATE block --
/// entirely spec-legal, ordinary zlib-compatible input that
/// `Compression.framework`'s decoder accepts identically to a genuinely
/// compressed stream -- so every decompressed byte is directly
/// controllable by the test itself.
@Suite("AssetImageValidator PNG streamed inflation production seams")
struct AssetImageValidatorPNGStreamingTests {
    private let limits = AssetCacheLimits(
        maxEncodedBytes: 200 * 1024 * 1024,
        maxDimension: 8192,
        maxPixelCount: 64_000_000,
        memoryBudgetBytes: 1024,
        diskBudgetBytes: 1024
    )

    /// Wraps `payload` in a single-block, uncompressed ("stored") RFC
    /// 1951 DEFLATE stream inside an RFC 1950 zlib container: a 2-byte
    /// zlib header (`0x78 0x01`, chosen so `(0x78*256+0x01) % 31 == 0`
    /// and FDICT is unset), a single final stored block (`0x01` header
    /// byte, byte-aligned LEN/NLEN, then the raw bytes verbatim), and a
    /// trailing big-endian Adler-32 of exactly `payload`.
    /// Wraps `payload` in one or more uncompressed ("stored") RFC 1951
    /// DEFLATE blocks inside an RFC 1950 zlib container: a 2-byte zlib
    /// header (`0x78 0x01`, chosen so `(0x78*256+0x01) % 31 == 0` and
    /// FDICT is unset), then as many stored blocks as needed (each
    /// capped at 65,535 bytes, the maximum a stored block's 16-bit LEN
    /// field can represent, with only the final block's BFINAL bit set),
    /// and a trailing big-endian Adler-32 of exactly `payload`.
    private func storedZlibStream(_ payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0x78, 0x01]
        let maxStoredBlockLength = 65535
        var offset = 0
        if payload.isEmpty {
            // A single, empty, final stored block: legal per RFC 1951
            // and the only way to represent a zero-length payload.
            bytes.append(0x01)
            bytes += withUnsafeBytes(of: UInt16(0).littleEndian, Array.init)
            bytes += withUnsafeBytes(of: UInt16(0xFFFF).littleEndian, Array.init)
        }
        while offset < payload.count {
            let end = min(offset + maxStoredBlockLength, payload.count)
            let isFinal = end == payload.count
            let chunkPayload = payload[offset ..< end]
            bytes.append(isFinal ? 0x01 : 0x00) // BFINAL, BTYPE=00 (stored)
            let len = UInt16(chunkPayload.count)
            let nlen = ~len
            bytes += withUnsafeBytes(of: len.littleEndian, Array.init)
            bytes += withUnsafeBytes(of: nlen.littleEndian, Array.init)
            bytes += chunkPayload
            offset = end
        }
        bytes += withUnsafeBytes(of: adler32(payload).bigEndian, Array.init)
        return bytes
    }

    private func adler32(_ bytes: [UInt8]) -> UInt32 {
        var sum1: UInt32 = 1
        var sum2: UInt32 = 0
        for byte in bytes {
            sum1 = (sum1 + UInt32(byte)) % 65521
            sum2 = (sum2 + sum1) % 65521
        }
        return (sum2 << 16) | sum1
    }

    private func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var bytes = [UInt8](withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        let typeAndPayload = Array(type.utf8) + payload
        bytes += typeAndPayload
        let crc = CRC32.checksum(Data(typeAndPayload))
        bytes += withUnsafeBytes(of: crc.bigEndian, Array.init)
        return bytes
    }

    /// Builds a minimal, hand-crafted, grayscale 8-bit-depth PNG with
    /// exactly `rawScanlines` as its decompressed `IDAT` payload (already
    /// including each row's leading filter byte) -- entirely independent
    /// of ImageIO, so every filter/pixel byte is under this test's direct
    /// control.
    private func makePNG(width: Int, height: Int, rawScanlines: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var ihdr: [UInt8] = []
        ihdr += withUnsafeBytes(of: UInt32(width).bigEndian, Array.init)
        ihdr += withUnsafeBytes(of: UInt32(height).bigEndian, Array.init)
        ihdr += [8, 0, 0, 0, 0] // 8-bit depth, grayscale, default compression/filter/interlace
        bytes += chunk("IHDR", ihdr)
        bytes += chunk("IDAT", storedZlibStream(rawScanlines))
        bytes += chunk("IEND", [])
        return Data(bytes)
    }

    @Test("A PNG whose IEND chunk carries a nonempty, CRC-correct payload is rejected")
    func nonEmptyIENDRejected() throws {
        let width = 4
        let height = 4
        var rawScanlines: [UInt8] = []
        for _ in 0 ..< height {
            rawScanlines.append(0) // filter type: None
            rawScanlines += [UInt8](repeating: 0, count: width)
        }
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var ihdr: [UInt8] = []
        ihdr += withUnsafeBytes(of: UInt32(width).bigEndian, Array.init)
        ihdr += withUnsafeBytes(of: UInt32(height).bigEndian, Array.init)
        ihdr += [8, 0, 0, 0, 0]
        bytes += chunk("IHDR", ihdr)
        bytes += chunk("IDAT", storedZlibStream(rawScanlines))
        // A structurally-invalid but still CRC-correct one-byte IEND
        // payload, exactly the shape the reviewer's evidence exercised:
        // the container-level walk's own CRC check still passes, and
        // ImageIO's lazy decoder does not reliably reject it either --
        // only an explicit `IEND` cardinality check can.
        bytes += chunk("IEND", [0x00])

        #expect(throws: AssetError.self) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("A PNG scanline beginning with an out-of-range filter-type byte is rejected")
    func invalidScanlineFilterByteRejected() throws {
        let width = 4
        let height = 3
        var rawScanlines: [UInt8] = []
        for row in 0 ..< height {
            // The PNG specification defines only filter types 0-4; a
            // legitimate encoder (and this pipeline's own fixture
            // builder) never emits anything else. Row 1 deliberately
            // uses an out-of-range value (5) to prove the streaming
            // validator actually inspects every row's leading byte, not
            // only the first.
            rawScanlines.append(row == 1 ? 5 : 0)
            rawScanlines += [UInt8](repeating: 0, count: width)
        }
        let png = makePNG(width: width, height: height, rawScanlines: rawScanlines)

        #expect(throws: AssetError.self) {
            _ = try AssetImageValidator.validate(
                data: png,
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("Every legal PNG filter-type byte (0 through 4) is accepted")
    func everyLegalFilterByteAccepted() throws {
        let width = 4
        for filterType: UInt8 in 0 ... 4 {
            var rawScanlines: [UInt8] = []
            rawScanlines.append(filterType)
            rawScanlines += [UInt8](repeating: 0, count: width)
            let png = makePNG(width: width, height: 1, rawScanlines: rawScanlines)
            let metadata = try AssetImageValidator.validate(
                data: png,
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
            #expect(metadata.width == width)
        }
    }

    @Test(
        """
        A PNG whose decompressed byte count spans many streaming iterations (far larger than \
        a single scratch-buffer's worth) still validates exactly, proving the streamed \
        validator never needs to materialize the full decompressed image at once
        """
    )
    func manyStreamingIterationsValidateExactly() throws {
        // 4000x3000 8-bit grayscale: 4000 + 1 filter byte per row, 3000
        // rows, ~12 MB decompressed -- deliberately many times larger
        // than any single fixed-size scratch buffer this validator uses
        // internally, so a correct implementation must span many
        // `compression_stream_process` iterations and accumulate the
        // running Adler-32/byte-count across all of them to pass.
        let width = 4000
        let height = 3000
        var rawScanlines: [UInt8] = []
        rawScanlines.reserveCapacity((width + 1) * height)
        for row in 0 ..< height {
            rawScanlines.append(0)
            // A few distinguishing nonzero bytes per row so a validator
            // that silently dropped or reordered streamed chunks would
            // fail the Adler-32 check rather than accidentally passing.
            rawScanlines.append(UInt8(row & 0xFF))
            rawScanlines += [UInt8](repeating: 0, count: width - 1)
        }
        let png = makePNG(width: width, height: height, rawScanlines: rawScanlines)

        let metadata = try AssetImageValidator.validate(
            data: png,
            declaredContentType: nil,
            expectedFormat: .png,
            limits: limits
        )
        #expect(metadata.width == width)
        #expect(metadata.height == height)
    }

    @Test(
        "A many-iteration PNG with a single corrupted byte deep in its payload is still rejected"
    )
    func manyStreamingIterationsCorruptionDetected() throws {
        let width = 4000
        let height = 3000
        var rawScanlines: [UInt8] = []
        rawScanlines.reserveCapacity((width + 1) * height)
        for _ in 0 ..< height {
            rawScanlines.append(0)
            rawScanlines += [UInt8](repeating: 0, count: width)
        }
        var png = [UInt8](makePNG(width: width, height: height, rawScanlines: rawScanlines))

        // Corrupt one byte deep inside the IDAT chunk's own *stored*
        // (uncompressed) DEFLATE payload, well past the first streaming
        // iteration's worth of output, then recompute the chunk's own
        // container-level CRC-32 so the corruption is invisible to the
        // structural walk and only detectable by actually decompressing
        // (here, literally copying) the bytes and comparing against the
        // trailing Adler-32, which still reflects the original,
        // uncorrupted payload.
        let idatTag: [UInt8] = Array("IDAT".utf8)
        guard let tagStart = png.firstRange(of: idatTag) else {
            Issue.record("Fixture must contain an IDAT chunk")
            return
        }
        let lengthStart = tagStart.lowerBound - 4
        let length = Int(
            UInt32(png[lengthStart]) << 24
                | UInt32(png[lengthStart + 1]) << 16
                | UInt32(png[lengthStart + 2]) << 8
                | UInt32(png[lengthStart + 3])
        )
        let dataStart = tagStart.upperBound
        let dataEnd = dataStart + length
        let corruptIndex = dataEnd - 100
        png[corruptIndex] ^= 0xFF
        let recomputedCRC = CRC32.checksum(Data(png[tagStart.lowerBound ..< dataEnd]))
        let crcBytes = withUnsafeBytes(of: recomputedCRC.bigEndian, Array.init)
        png.replaceSubrange(dataEnd ..< dataEnd + 4, with: crcBytes)

        #expect(throws: AssetError.self) {
            _ = try AssetImageValidator.validate(
                data: Data(png),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }
}
