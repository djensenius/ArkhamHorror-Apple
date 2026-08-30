@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for ``AssetImageValidator``'s quantization-table (`DQT`)
/// validation (`AssetImageValidator+JPEGSegments.swift`'s
/// `parseJPEGQuantizationTables`, and the referenced-table existence
/// check `AssetImageValidator+JPEGStructure.swift`'s
/// `handleStartOfScan` performs before entropy decoding begins).
///
/// Before this suite's own production code existed, `DQT` was treated as
/// an entirely opaque length-prefixed segment: a frame component's own
/// quantization-table selector was range-checked (0-3) but never proven
/// to resolve to an actually-defined table, and a defined table's own
/// coefficients were never proven nonzero. ImageIO's decoder silently
/// "repairs" both defects (substituting some default/undefined table
/// state) well enough to still produce a `CGImage`, which is exactly the
/// kind of leniency this pipeline's own strict validators exist to close
/// before anything reaches the cache.
struct AssetImageValidatorJPEGDQTTests {
    private let limits = AssetCacheLimits(
        maxEncodedBytes: 20 * 1024 * 1024,
        maxDimension: 8192,
        maxPixelCount: 32_000_000,
        memoryBudgetBytes: 1024,
        diskBudgetBytes: 1024
    )

    /// A minimal, genuinely single-MCU baseline JPEG (SOI/SOF0/DHT
    /// (DC+AC)/SOS/one entropy byte/EOI) identical in shape to the
    /// existing happy-path fixtures in `AssetImageValidatorJPEGTests.swift`
    /// and `AssetImageValidatorJPEGEntropyTests.swift`, parameterized so
    /// this suite can freely omit/corrupt only the `DQT` segment itself
    /// while keeping every other segment held constant.
    private func minimalJPEGBytes(dqtSegment: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        bytes += dqtSegment
        bytes += [0xFF, 0xC0] // SOF0
        bytes += [0x00, 0x0B]
        bytes += [0x08] // precision
        bytes += [0x00, 0x06] // height
        bytes += [0x00, 0x06] // width
        bytes += [0x01] // component count
        bytes += [0x01, 0x11, 0x00] // component: id 1, sampling 1x1, quant table 0
        bytes += [0xFF, 0xC4, 0x00, 0x14, 0x00] // minimal DC Huffman table (dest 0)
        bytes += [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00]
        bytes += [0xFF, 0xC4, 0x00, 0x14, 0x10] // minimal AC Huffman table (dest 0)
        bytes += [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0x00]
        bytes += [0xFF, 0xDA] // SOS
        bytes += [0x00, 0x08]
        bytes += [0x01]
        bytes += [0x01, 0x00]
        bytes += [0x00, 0x3F, 0x00]
        bytes += [0b0011_1111] // DC "0" + AC EOB "0", padded with 1s
        bytes += [0xFF, 0xD9] // EOI
        return bytes
    }

    /// A single, genuinely valid `DQT` segment defining destination 0 at
    /// 8-bit precision with all-`0x01` coefficients (legal: every
    /// coefficient nonzero).
    private func validDQT(destination: UInt8 = 0) -> [UInt8] {
        var bytes: [UInt8] = [0xFF, 0xDB, 0x00, 0x43, destination]
        bytes += [UInt8](repeating: 0x01, count: 64)
        return bytes
    }

    @Test("A frame component whose quant-table selector has no matching DQT definition is rejected")
    func missingQuantizationTableRejected() throws {
        let bytes = minimalJPEGBytes(dqtSegment: [])

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test("A DQT table defining an unreferenced destination does not satisfy a different selector")
    func wrongDestinationDQTRejected() throws {
        // Defines destination 1, but the component descriptor (baked
        // into `minimalJPEGBytes`) selects destination 0.
        let bytes = minimalJPEGBytes(dqtSegment: validDQT(destination: 1))

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test("A DQT table containing a zero coefficient is rejected")
    func zeroCoefficientDQTRejected() throws {
        var dqt: [UInt8] = [0xFF, 0xDB, 0x00, 0x43, 0x00]
        var coefficients = [UInt8](repeating: 0x01, count: 64)
        coefficients[17] = 0x00 // one illegal zero coefficient, mid-table
        dqt += coefficients
        let bytes = minimalJPEGBytes(dqtSegment: dqt)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test("A DQT table with an invalid precision nibble (neither 0 nor 1) is rejected")
    func invalidPrecisionDQTRejected() throws {
        var dqt: [UInt8] = [0xFF, 0xDB, 0x00, 0x43, 0x20] // precision nibble = 2
        dqt += [UInt8](repeating: 0x01, count: 64)
        let bytes = minimalJPEGBytes(dqtSegment: dqt)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test("A DQT table with an out-of-range destination nibble (> 3) is rejected")
    func invalidDestinationDQTRejected() throws {
        var dqt: [UInt8] = [0xFF, 0xDB, 0x00, 0x43, 0x04] // destination nibble = 4
        dqt += [UInt8](repeating: 0x01, count: 64)
        let bytes = minimalJPEGBytes(dqtSegment: dqt)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test("A DQT segment declaring a length inconsistent with a whole number of tables is rejected")
    func truncatedDQTRejected() throws {
        // Declares a 67-byte segment (1 precision/dest byte + 64
        // coefficients) but only supplies 40 coefficient bytes.
        var dqt: [UInt8] = [0xFF, 0xDB, 0x00, 0x43, 0x00]
        dqt += [UInt8](repeating: 0x01, count: 40)
        let bytes = minimalJPEGBytes(dqtSegment: dqt)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }

    @Test("A valid DQT table with a genuinely matching destination is accepted")
    func validMatchingDQTAccepted() throws {
        let bytes = minimalJPEGBytes(dqtSegment: validDQT(destination: 0))

        let metadata = try AssetImageValidator.validate(
            data: Data(bytes),
            declaredContentType: nil,
            expectedFormat: .jpeg,
            limits: limits
        )
        #expect(metadata.width == 6)
        #expect(metadata.height == 6)
    }

    @Test("A 16-bit-precision DQT table with a genuinely matching destination is accepted")
    func wide16BitPrecisionDQTAccepted() throws {
        var dqt: [UInt8] = [0xFF, 0xDB]
        // Length: 2 (length field) + 1 (precision/dest byte) + 64*2
        // (16-bit coefficients) = 131 = 0x0083.
        dqt += [0x00, 0x83]
        dqt += [0x10] // precision nibble = 1 (16-bit), destination 0
        for _ in 0 ..< 64 {
            dqt += [0x00, 0x01] // big-endian 1, nonzero
        }
        let bytes = minimalJPEGBytes(dqtSegment: dqt)

        let metadata = try AssetImageValidator.validate(
            data: Data(bytes),
            declaredContentType: nil,
            expectedFormat: .jpeg,
            limits: limits
        )
        #expect(metadata.width == 6)
        #expect(metadata.height == 6)
    }

    @Test("A real, ImageIO-encoded JPEG's own DQT tables validate against its own SOF components")
    func realJPEGValidatesOwnQuantizationTables() throws {
        let jpeg = AssetImageFixtureBuilder.validJPEG(width: 6, height: 6)
        let metadata = try AssetImageValidator.validate(
            data: jpeg,
            declaredContentType: nil,
            expectedFormat: .jpeg,
            limits: limits
        )
        #expect(metadata.width == 6)
        #expect(metadata.height == 6)
    }
}
