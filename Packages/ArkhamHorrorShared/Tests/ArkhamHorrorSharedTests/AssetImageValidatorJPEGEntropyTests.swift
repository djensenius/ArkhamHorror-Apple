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
        A SOF frame header declaring two components with the same component ID is rejected -- \
        ImageIO's own decoder silently repairs/resolves this ambiguity, but this package's own \
        entropy-coverage proof depends on frame component IDs being unique so a scan's selector \
        set can be safely matched against them
        """
    )
    func duplicateFrameComponentIDsRejected() throws {
        // A fully well-formed, otherwise-decodable single-scan image
        // (deliberately *not* a truncated fragment): with the frame's
        // own component-ID uniqueness guard removed, this decodes
        // successfully (both scan components resolve, via `.first`, to
        // the very same physical frame component) and produces metadata
        // -- proving the vulnerability is decode-reachable, not merely
        // hypothetical -- while the fixed decoder rejects it up front.
        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        bytes += [0xFF, 0xC0] // SOF0
        bytes += [0x00, 0x0E] // length = 14 (2 components)
        bytes += [0x08] // precision
        bytes += [0x00, 0x06] // height = 6
        bytes += [0x00, 0x06] // width = 6
        bytes += [0x02] // component count = 2
        bytes += [0x01, 0x11, 0x00] // component: id = 1
        bytes += [0x01, 0x11, 0x00] // component: id = 1 again (duplicate!)
        // DQT (destination 0, referenced by both components above).
        bytes += [0xFF, 0xDB, 0x00, 0x43, 0x00]
        bytes += [UInt8](repeating: 0x01, count: 64)
        // DHT DC table (class 0, destination 0): one length-1 code -> symbol 0.
        bytes += [0xFF, 0xC4, 0x00, 0x14, 0x00]
        bytes += [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00]
        // DHT AC table (class 1, destination 0): one length-1 code -> symbol 0 (EOB).
        bytes += [0xFF, 0xC4, 0x00, 0x14, 0x10]
        bytes += [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00]
        bytes += [0xFF, 0xDA] // SOS
        bytes += [0x00, 0x0A] // SOS header length = 10 (2 scan components)
        bytes += [0x02] // Ns = 2
        bytes += [0x01, 0x00] // selector = 1 (DC0/AC0)
        bytes += [0x01, 0x00] // selector = 1 again -- both resolve to the one frame component
        bytes += [0x00, 0x3F, 0x00]
        // One MCU, two DUs (both id=1): each DU is "0" (DC=0) + "0" (AC
        // EOB) = 4 meaningful bits total, padded with 1s to a byte.
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

    @Test(
        """
        A scan (SOS) whose component selectors are a duplicate subset of the frame's component \
        IDs -- same count, but not the same set -- is rejected: it would otherwise decode \
        "successfully" while repeatedly resolving one frame component and leaving another \
        completely unscanned/unverified by this coverage proof
        """
    )
    func scanSelectorSetNotEqualToFrameComponentSetRejected() throws {
        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        bytes += [0xFF, 0xC0] // SOF0
        bytes += [0x00, 0x0E] // length = 14 (2 components)
        bytes += [0x08] // precision
        bytes += [0x00, 0x06] // height = 6
        bytes += [0x00, 0x06] // width = 6
        bytes += [0x02] // component count = 2
        bytes += [0x01, 0x11, 0x00] // component: id = 1
        bytes += [0x02, 0x11, 0x00] // component: id = 2 (distinct -- valid frame)
        // DQT (destination 0, referenced by both components above).
        bytes += [0xFF, 0xDB, 0x00, 0x43, 0x00]
        bytes += [UInt8](repeating: 0x01, count: 64)
        // DHT DC table (class 0, destination 0).
        bytes += [0xFF, 0xC4, 0x00, 0x14, 0x00]
        bytes += [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00]
        // DHT AC table (class 1, destination 0).
        bytes += [0xFF, 0xC4, 0x00, 0x14, 0x10]
        bytes += [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00]
        bytes += [0xFF, 0xDA] // SOS
        bytes += [0x00, 0x0A] // SOS header length = 10 (2 scan components)
        bytes += [0x02] // Ns = 2
        bytes += [0x01, 0x00] // selector = 1 (DC0/AC0)
        bytes += [0x01, 0x00] // selector = 1 again (duplicate -- component 2 never scanned!)
        bytes += [0x00, 0x3F, 0x00]
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
}
