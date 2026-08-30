@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for ``AssetImageValidator``'s strict baseline-JPEG entropy-
/// coded-scan decoder (`AssetImageValidator+JPEGEntropy.swift`), which
/// sits beyond `validateJPEGStructure(_:)`'s own marker/length walk: that
/// walk only proves *some* non-empty span of bytes exists between `SOS`
/// and the next real marker, correctly skipping byte-stuffed `FF 00` and
/// in-scan restart markers -- a single arbitrary byte of "entropy data"
/// already satisfies it. This corrupts bytes *within* a real fixture's
/// own entropy-coded scan data (same total length, so the container-
/// level walk and `AssetImageValidatorTruncationTests.swift`'s own
/// prefix-truncation coverage cannot exercise this class of corruption
/// at all) and proves genuine Huffman/MCU coverage -- not merely "some
/// CGImage was eventually produced" -- gates what is cached.
@Suite("AssetImageValidator JPEG entropy coverage")
struct AssetImageValidatorJPEGEntropyTests {
    private let limits = AssetCacheLimits(
        maxEncodedBytes: 20 * 1024 * 1024,
        maxDimension: 8192,
        maxPixelCount: 32_000_000,
        memoryBudgetBytes: 1024,
        diskBudgetBytes: 1024
    )

    /// Locates a real fixture's `SOS` marker and returns the offset of its
    /// own entropy-coded scan data (immediately after the SOS header).
    private func entropyDataStart(in bytes: [UInt8]) throws -> Int {
        guard let sosStart = bytes.firstRange(of: [0xFF, 0xDA]) else {
            Issue.record("Fixture must contain an SOS marker")
            throw AssetError.malformedImageData
        }
        let sosHeaderLength = Int(bytes[sosStart.upperBound]) << 8
            | Int(bytes[sosStart.upperBound + 1])
        return sosStart.upperBound + sosHeaderLength
    }

    @Test("A real, untampered JPEG's entropy-coded scan data decodes as a complete MCU raster")
    func realJPEGDecodesExactly() throws {
        let data = AssetImageFixtureBuilder.validJPEG(width: 12, height: 5)
        let metadata = try AssetImageValidator.validate(
            data: data,
            declaredContentType: "image/jpeg",
            expectedFormat: .jpeg,
            limits: limits
        )
        #expect(metadata.width == 12)
        #expect(metadata.height == 5)
    }

    @Test(
        """
        A single bit flipped early in a real JPEG's entropy-coded scan data (not its length -- \
        every marker/segment boundary and the EOI's own position stay byte-for-byte identical) \
        is rejected by the strict Huffman/MCU decoder even though the marker-walk-only check \
        alone would accept it
        """
    )
    func corruptedEntropyByteNearStartRejected() throws {
        var bytes = [UInt8](AssetImageFixtureBuilder.validJPEG(width: 12, height: 5))
        let entropyStart = try entropyDataStart(in: bytes)
        bytes[entropyStart] ^= 0xFF

        #expect(throws: AssetError.self) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test("A single bit flipped in the middle of a real JPEG's entropy-coded scan data is rejected")
    func corruptedEntropyByteInMiddleRejected() throws {
        var bytes = [UInt8](AssetImageFixtureBuilder.validJPEG(width: 100, height: 100))
        let entropyStart = try entropyDataStart(in: bytes)
        guard let eoiStart = bytes.lastRange(of: [0xFF, 0xD9]) else {
            Issue.record("Fixture must contain an EOI marker")
            return
        }
        let entropyEnd = eoiStart.lowerBound
        let midpoint = entropyStart + (entropyEnd - entropyStart) / 2
        guard midpoint < bytes.count, bytes[midpoint] != 0xFF else {
            // Avoid corrupting a byte-stuffing/restart-marker prefix
            // byte itself, which would change the buffer's own marker
            // structure rather than exercise the Huffman decoder.
            Issue.record("Unexpected 0xFF at the chosen midpoint; adjust the fixture/offset")
            return
        }
        bytes[midpoint] ^= 0x01

        #expect(throws: AssetError.self) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test(
        """
        A progressive JPEG (SOF2) is rejected as unsupported rather than mis-validated by the \
        baseline-only decoder
        """
    )
    func progressiveJPEGRejected() throws {
        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        bytes += [0xFF, 0xC2] // SOF2 (progressive)
        bytes += [0x00, 0x0B] // length = 11
        bytes += [0x08] // precision
        bytes += [0x00, 0x06] // height = 6
        bytes += [0x00, 0x06] // width = 6
        bytes += [0x01] // component count = 1
        bytes += [0x01, 0x11, 0x00] // one component descriptor
        bytes += [0xFF, 0xDA] // SOS marker
        bytes += [0x00, 0x08] // SOS header length = 8
        bytes += [0x01] // Ns = 1
        bytes += [0x01, 0x00]
        bytes += [0x00, 0x3F, 0x00]
        bytes += [0x00]
        bytes += [0xFF, 0xD9] // EOI

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test(
        """
        A DHT table referencing an unsupported class nibble is rejected rather than silently \
        ignored
        """
    )
    func invalidHuffmanTableClassRejected() throws {
        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        bytes += [0xFF, 0xC0] // SOF0
        bytes += [0x00, 0x0B]
        bytes += [0x08]
        bytes += [0x00, 0x06]
        bytes += [0x00, 0x06]
        bytes += [0x01]
        bytes += [0x01, 0x11, 0x00]
        // A DHT table with class nibble 2 (invalid: only 0=DC, 1=AC exist).
        bytes += [0xFF, 0xC4, 0x00, 0x14, 0x20]
        bytes += [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00]
        bytes += [0xFF, 0xDA]
        bytes += [0x00, 0x08]
        bytes += [0x01]
        bytes += [0x01, 0x00]
        bytes += [0x00, 0x3F, 0x00]
        bytes += [0x00]
        bytes += [0xFF, 0xD9]

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test("An over-subscribed Huffman BITS table (more codes at a length than fit) is rejected")
    func overSubscribedHuffmanTableRejected() throws {
        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        bytes += [0xFF, 0xC0] // SOF0
        bytes += [0x00, 0x0B]
        bytes += [0x08]
        bytes += [0x00, 0x06]
        bytes += [0x00, 0x06]
        bytes += [0x01]
        bytes += [0x01, 0x11, 0x00]
        // A DC DHT table declaring 3 one-bit codes -- a 1-bit code space
        // only has 2 possible values, so this is over-subscribed.
        bytes += [0xFF, 0xC4, 0x00, 0x16, 0x00]
        bytes += [0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x01, 0x02]
        bytes += [0xFF, 0xDA]
        bytes += [0x00, 0x08]
        bytes += [0x01]
        bytes += [0x01, 0x00]
        bytes += [0x00, 0x3F, 0x00]
        bytes += [0x00]
        bytes += [0xFF, 0xD9]

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test("A restart interval whose expected restart marker is missing/wrong is rejected")
    func missingRestartMarkerRejected() throws {
        // Two 1x1-sampled 8x8-block MCUs (16x8 image, restart interval 1
        // MCU) but the entropy data omits the restart marker between
        // them entirely -- the second MCU's Huffman-coded bits begin
        // immediately, so the decoder (expecting a byte-aligned restart
        // marker first) must reject rather than resynchronize by luck.
        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        bytes += [0xFF, 0xC0] // SOF0
        bytes += [0x00, 0x0B]
        bytes += [0x08]
        bytes += [0x00, 0x08] // height = 8
        bytes += [0x00, 0x10] // width = 16 (two 8x8 MCUs horizontally)
        bytes += [0x01]
        bytes += [0x01, 0x11, 0x00]
        bytes += [0xFF, 0xC4, 0x00, 0x14, 0x00]
        bytes += [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00]
        bytes += [0xFF, 0xC4, 0x00, 0x14, 0x10]
        bytes += [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00]
        // DRI: restart every 1 MCU.
        bytes += [0xFF, 0xDD, 0x00, 0x04, 0x00, 0x01]
        bytes += [0xFF, 0xDA]
        bytes += [0x00, 0x08]
        bytes += [0x01]
        bytes += [0x01, 0x00]
        bytes += [0x00, 0x3F, 0x00]
        // Two MCUs' worth of entropy bits back-to-back with NO restart
        // marker spliced between them (each MCU is 2 bits: DC "0" + AC
        // EOB "0"), padded to a whole byte with 1s.
        bytes += [0b0000_1111]
        bytes += [0xFF, 0xD9] // EOI

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test("A correctly-placed restart marker between two MCUs is accepted")
    func correctRestartMarkerAccepted() throws {
        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        bytes += [0xFF, 0xC0] // SOF0
        bytes += [0x00, 0x0B]
        bytes += [0x08]
        bytes += [0x00, 0x08] // height = 8
        bytes += [0x00, 0x10] // width = 16 (two 8x8 MCUs horizontally)
        bytes += [0x01]
        bytes += [0x01, 0x11, 0x00]
        bytes += [0xFF, 0xC4, 0x00, 0x14, 0x00]
        bytes += [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00]
        bytes += [0xFF, 0xC4, 0x00, 0x14, 0x10]
        bytes += [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00]
        bytes += [0xFF, 0xDD, 0x00, 0x04, 0x00, 0x01] // DRI: restart every 1 MCU
        bytes += [0xFF, 0xDA]
        bytes += [0x00, 0x08]
        bytes += [0x01]
        bytes += [0x01, 0x00]
        bytes += [0x00, 0x3F, 0x00]
        // MCU 1: DC "0" + AC EOB "0", padded with 1s to a byte boundary.
        bytes += [0b0011_1111]
        bytes += [0xFF, 0xD0] // RST0
        // MCU 2: DC "0" + AC EOB "0", padded with 1s to a byte boundary.
        bytes += [0b0011_1111]
        bytes += [0xFF, 0xD9] // EOI

        let metadata = try AssetImageValidator.validate(
            data: Data(bytes),
            declaredContentType: nil,
            expectedFormat: .jpeg,
            limits: limits
        )
        #expect(metadata.width == 16)
        #expect(metadata.height == 8)
    }
}
