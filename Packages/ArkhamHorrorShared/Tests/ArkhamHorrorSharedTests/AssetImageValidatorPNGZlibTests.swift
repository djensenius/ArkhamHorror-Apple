@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for ``AssetImageValidator``'s exact zlib/DEFLATE inflation
/// check (`AssetImageValidator+PNGZlib.swift`), which sits beyond both the
/// pure `IHDR`-only dimension parse and the container-level chunk/CRC
/// structural walk (`AssetImageValidatorTruncationTests.swift`): it
/// corrupts bytes *within* a real, structurally-valid fixture's own
/// `IDAT` payload (same total length, so chunk lengths/CRCs and the
/// truncation suite's own prefix-based coverage cannot exercise this
/// class of corruption at all) and proves the exact decompressed byte
/// count -- not merely "some CGImage was eventually produced" -- gates
/// what is cached.
@Suite("AssetImageValidator PNG zlib exact inflation")
struct AssetImageValidatorPNGZlibTests {
    private let limits = AssetCacheLimits(
        maxEncodedBytes: 20 * 1024 * 1024,
        maxDimension: 8192,
        maxPixelCount: 32_000_000,
        memoryBudgetBytes: 1024,
        diskBudgetBytes: 1024
    )

    @Test(
        "A real, untampered PNG's IDAT payload decompresses to exactly its own expected byte count"
    )
    func realPNGInflatesExactly() throws {
        let png = AssetImageFixtureBuilder.validPNG(width: 6, height: 9)
        let colorInfo = try AssetImageValidator.parsePNGColorInfo(png)
        let rowByteCount = try AssetImageValidator.pngRowByteCount(
            width: 6,
            colorInfo: colorInfo
        )
        let rowCount = 9
        let idatPayload = try AssetImageValidator.validatePNGStructure(png)
        try AssetImageValidator.validateExactPNGInflation(
            idatPayload: idatPayload,
            rowByteCount: rowByteCount,
            rowCount: rowCount
        )
    }

    @Test(
        """
        A single bit flipped inside a real PNG's compressed IDAT bytes (not its length --
        every chunk length/CRC/container structure stays byte-for-byte valid) is rejected \
        by the exact-inflation check even though the container-level structural walk alone \
        would accept it
        """
    )
    func corruptedCompressedByteWithinIDATRejected() throws {
        var bytes = [UInt8](AssetImageFixtureBuilder.validPNG(width: 6, height: 9))
        let idatTag: [UInt8] = Array("IDAT".utf8)
        guard let tagStart = bytes.firstRange(of: idatTag) else {
            Issue.record("Fixture must contain an IDAT chunk")
            return
        }
        // Recompute this chunk's own CRC-32 after corrupting one byte of
        // its *compressed* payload, so the corruption is invisible to the
        // container-level walk (whose CRC check this deliberately keeps
        // passing) and only detectable by actually inflating the bytes.
        let dataStart = tagStart.upperBound
        // A few bytes in, past the 2-byte zlib header, so the corruption
        // lands inside the actual DEFLATE-compressed data rather than the
        // header this validator itself separately parses.
        let corruptIndex = dataStart + 4
        guard corruptIndex < bytes.count else {
            Issue.record("Fixture's IDAT chunk must have enough compressed bytes to corrupt")
            return
        }
        bytes[corruptIndex] ^= 0xFF

        let lengthStart = tagStart.lowerBound - 4
        guard let length = AssetImageValidator.readUInt32BE(Data(bytes), at: lengthStart) else {
            Issue.record("Must be able to read the IDAT chunk's own declared length")
            return
        }
        let chunkDataEnd = dataStart + Int(length)
        let crcStart = chunkDataEnd
        let recomputedCRC = CRC32.checksum(Data(bytes[tagStart.lowerBound ..< chunkDataEnd]))
        let crcBytes = withUnsafeBytes(of: recomputedCRC.bigEndian, Array.init)
        bytes.replaceSubrange(crcStart ..< crcStart + 4, with: crcBytes)

        let corrupted = Data(bytes)
        #expect(throws: AssetError.self) {
            _ = try AssetImageValidator.validate(
                data: corrupted,
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test(
        """
        A concatenated IDAT payload one byte longer than its own valid zlib stream \
        (trailing garbage appended after a clean end-of-stream) is rejected
        """
    )
    func trailingGarbageAfterValidZlibStreamRejected() throws {
        let png = AssetImageFixtureBuilder.validPNG(width: 4, height: 4)
        let colorInfo = try AssetImageValidator.parsePNGColorInfo(png)
        let rowByteCount = try AssetImageValidator.pngRowByteCount(
            width: 4,
            colorInfo: colorInfo
        )
        let rowCount = 4
        var idatPayload = try AssetImageValidator.validatePNGStructure(png)
        idatPayload.append(0x00)

        #expect(throws: AssetError.self) {
            try AssetImageValidator.validateExactPNGInflation(
                idatPayload: idatPayload,
                rowByteCount: rowByteCount,
                rowCount: rowCount
            )
        }
    }

    @Test(
        """
        A payload that decompresses to fewer bytes than expected (truncated mid-stream) is \
        rejected
        """
    )
    func shortDecompressedOutputRejected() throws {
        let png = AssetImageFixtureBuilder.validPNG(width: 6, height: 9)
        let colorInfo = try AssetImageValidator.parsePNGColorInfo(png)
        let rowByteCount = try AssetImageValidator.pngRowByteCount(
            width: 6,
            colorInfo: colorInfo
        )
        let rowCount = 9
        let idatPayload = try AssetImageValidator.validatePNGStructure(png)

        #expect(throws: AssetError.self) {
            // Claiming a byte count larger than what this exact, valid
            // stream actually inflates to reproduces the "too few
            // decompressed bytes" case without needing a second corrupted
            // fixture: the real stream still ends cleanly and consumes
            // all its input, but at a byte count short of what is now
            // (falsely) expected.
            try AssetImageValidator.validateExactPNGInflation(
                idatPayload: idatPayload,
                rowByteCount: rowByteCount,
                rowCount: rowCount + 1
            )
        }
    }

    @Test("A payload claimed to decompress to fewer bytes than it actually does is rejected")
    func longDecompressedOutputRejected() throws {
        let png = AssetImageFixtureBuilder.validPNG(width: 6, height: 9)
        let colorInfo = try AssetImageValidator.parsePNGColorInfo(png)
        let rowByteCount = try AssetImageValidator.pngRowByteCount(
            width: 6,
            colorInfo: colorInfo
        )
        let rowCount = 9
        let idatPayload = try AssetImageValidator.validatePNGStructure(png)

        #expect(throws: AssetError.self) {
            try AssetImageValidator.validateExactPNGInflation(
                idatPayload: idatPayload,
                rowByteCount: rowByteCount,
                rowCount: rowCount - 1
            )
        }
    }

    @Test("An IDAT payload with a corrupted zlib header (bad CM nibble) is rejected")
    func corruptedZlibHeaderRejected() throws {
        let png = AssetImageFixtureBuilder.validPNG(width: 4, height: 4)
        let colorInfo = try AssetImageValidator.parsePNGColorInfo(png)
        let rowByteCount = try AssetImageValidator.pngRowByteCount(
            width: 4,
            colorInfo: colorInfo
        )
        let rowCount = 4
        var idatPayload = try [UInt8](AssetImageValidator.validatePNGStructure(png))
        // Corrupt the CM nibble (must be 8 for DEFLATE) without touching
        // the header-checksum bits, so this specifically exercises the
        // "CM != 8" guard rather than the header-checksum guard.
        idatPayload[0] = (idatPayload[0] & 0xF0) | 0x03

        #expect(throws: AssetError.self) {
            try AssetImageValidator.validateExactPNGInflation(
                idatPayload: Data(idatPayload),
                rowByteCount: rowByteCount,
                rowCount: rowCount
            )
        }
    }

    @Test(
        """
        An IDAT payload with a corrupted Adler-32 trailer is rejected despite otherwise-exact \
        inflation
        """
    )
    func corruptedAdler32TrailerRejected() throws {
        let png = AssetImageFixtureBuilder.validPNG(width: 4, height: 4)
        let colorInfo = try AssetImageValidator.parsePNGColorInfo(png)
        let rowByteCount = try AssetImageValidator.pngRowByteCount(
            width: 4,
            colorInfo: colorInfo
        )
        let rowCount = 4
        var idatPayload = try [UInt8](AssetImageValidator.validatePNGStructure(png))
        idatPayload[idatPayload.count - 1] ^= 0xFF

        #expect(throws: AssetError.self) {
            try AssetImageValidator.validateExactPNGInflation(
                idatPayload: Data(idatPayload),
                rowByteCount: rowByteCount,
                rowCount: rowCount
            )
        }
    }

    @Test(
        """
        Adam7-interlaced IHDR (interlace method 1) is rejected as unsupported rather than \
        mis-validated
        """
    )
    func interlacedPNGRejected() throws {
        let colorInfo = AssetImageValidator.PNGColorInfo(
            bitDepth: 8,
            colorType: 6,
            interlaceMethod: 1
        )
        #expect(throws: AssetError.self) {
            _ = try AssetImageValidator.expectedPNGScanlineByteCount(
                width: 4,
                height: 4,
                colorInfo: colorInfo
            )
        }
    }

    @Test(
        """
        An invalid PNG color type is rejected rather than silently defaulting to some channel \
        count
        """
    )
    func invalidColorTypeRejected() throws {
        let colorInfo = AssetImageValidator.PNGColorInfo(
            bitDepth: 8,
            colorType: 5,
            interlaceMethod: 0
        )
        #expect(throws: AssetError.self) {
            _ = try AssetImageValidator.expectedPNGScanlineByteCount(
                width: 4,
                height: 4,
                colorInfo: colorInfo
            )
        }
    }

    @Test("An invalid PNG bit depth is rejected rather than silently accepted")
    func invalidBitDepthRejected() throws {
        let colorInfo = AssetImageValidator.PNGColorInfo(
            bitDepth: 3,
            colorType: 0,
            interlaceMethod: 0
        )
        #expect(throws: AssetError.self) {
            _ = try AssetImageValidator.expectedPNGScanlineByteCount(
                width: 4,
                height: 4,
                colorInfo: colorInfo
            )
        }
    }
}
