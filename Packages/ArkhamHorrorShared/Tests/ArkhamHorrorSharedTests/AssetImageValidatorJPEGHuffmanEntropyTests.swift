@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Huffman-table and restart-interval coverage for
/// `AssetImageValidator`'s strict baseline-JPEG entropy-coded-scan
/// decoder. Split out of `AssetImageValidatorJPEGEntropyTests.swift`
/// purely to keep that file within this package's `file_length`/
/// `type_body_length` conventions.
@Suite("AssetImageValidator JPEG Huffman/restart-interval entropy coverage")
struct AssetImageValidatorHuffmanEntropyTests {
    private let limits = AssetCacheLimits(
        maxEncodedBytes: 20 * 1024 * 1024,
        maxDimension: 8192,
        maxPixelCount: 32_000_000,
        memoryBudgetBytes: 1024,
        diskBudgetBytes: 1024
    )

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
        bytes += [0xFF, 0xDB, 0x00, 0x43, 0x00]
        bytes += [UInt8](repeating: 0x01, count: 64)
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
