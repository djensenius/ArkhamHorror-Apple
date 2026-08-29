@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves that truncating or corrupting a *real, genuinely decodable*
/// PNG/JPEG fixture at any point is rejected by
/// ``AssetImageValidator``'s structural walk — not merely a hand-built,
/// always-incomplete header-only shell (see ``AssetImageFixtureBuilder/pngHeaderOnly``/
/// ``jpegHeaderOnly``, which exercise the same gate but were never a
/// genuinely-complete file to begin with).
///
/// A PNG's terminal `IEND` chunk (and a JPEG's terminal `EOI` marker) is
/// only ever satisfied by the *exact* full byte count of the real,
/// complete fixture: any strict prefix necessarily ends somewhere inside
/// an earlier chunk/segment or entropy run, never coincidentally landing
/// on its own separate, complete terminator, for the small fixtures this
/// suite builds. So exhaustively truncating at every length from just
/// past the signature/SOI to one byte short of the full file reproduces
/// exactly what the underlying review found reproducible against the
/// prior (`IHDR`-only / first-`SOF`-only) parser: real bytes cut off
/// mid-`IDAT` or mid-entropy-scan that must now be rejected, not merely
/// synthetic always-empty shells.
@Suite("AssetImageValidator real-fixture truncation/corruption")
struct AssetImageValidatorTruncationTests {
    private let limits = AssetCacheLimits(
        maxEncodedBytes: 20 * 1024 * 1024,
        maxDimension: 8192,
        maxPixelCount: 32_000_000,
        memoryBudgetBytes: 1024,
        diskBudgetBytes: 1024
    )

    @Test("Every strict prefix of a real, complete PNG shorter than the full file is rejected")
    func everyTruncatedPNGPrefixRejected() throws {
        let full = AssetImageFixtureBuilder.validPNG(width: 4, height: 4)
        for length in 8 ..< full.count {
            let truncated = full.prefix(length)
            #expect(throws: AssetError.self, "truncated to \(length) of \(full.count) bytes") {
                _ = try AssetImageValidator.validate(
                    data: Data(truncated),
                    declaredContentType: nil,
                    expectedFormat: .png,
                    limits: limits
                )
            }
        }
    }

    @Test("Every strict prefix of a real, complete JPEG shorter than the full file is rejected")
    func everyTruncatedJPEGPrefixRejected() throws {
        let full = AssetImageFixtureBuilder.validJPEG(width: 4, height: 4)
        for length in 2 ..< full.count {
            let truncated = full.prefix(length)
            #expect(throws: AssetError.self, "truncated to \(length) of \(full.count) bytes") {
                _ = try AssetImageValidator.validate(
                    data: Data(truncated),
                    declaredContentType: nil,
                    expectedFormat: .jpeg,
                    limits: limits
                )
            }
        }
    }

    @Test("The complete, untruncated real PNG/JPEG fixtures still validate and decode")
    func untruncatedRealFixturesStillValidate() throws {
        let png = AssetImageFixtureBuilder.validPNG(width: 4, height: 4)
        let pngMetadata = try AssetImageValidator.validate(
            data: png,
            declaredContentType: nil,
            expectedFormat: .png,
            limits: limits
        )
        #expect(pngMetadata.width == 4)
        #expect(pngMetadata.height == 4)
        _ = try AssetImageDecoder.decode(png)

        let jpeg = AssetImageFixtureBuilder.validJPEG(width: 4, height: 4)
        let jpegMetadata = try AssetImageValidator.validate(
            data: jpeg,
            declaredContentType: nil,
            expectedFormat: .jpeg,
            limits: limits
        )
        #expect(jpegMetadata.width == 4)
        #expect(jpegMetadata.height == 4)
        _ = try AssetImageDecoder.decode(jpeg)
    }

    @Test("A single corrupted byte inside a real PNG's IDAT chunk fails its chunk CRC-32 check")
    func corruptedIDATByteFailsCRCCheck() throws {
        var bytes = [UInt8](AssetImageFixtureBuilder.validPNG(width: 4, height: 4))
        let idatTag: [UInt8] = Array("IDAT".utf8)
        guard let tagStart = bytes.firstRange(of: idatTag) else {
            Issue.record("Fixture must contain an IDAT chunk")
            return
        }
        // One byte into the chunk's data, immediately after its 4-byte
        // type tag: guaranteed to be part of the actual compressed
        // payload the chunk's stored CRC-32 covers, for any nonempty
        // IDAT chunk.
        let corruptIndex = tagStart.upperBound
        bytes[corruptIndex] ^= 0xFF

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("A corrupted byte inside a real PNG's terminal IEND chunk's own CRC-32 is rejected")
    func corruptedIENDCRCRejected() throws {
        var bytes = [UInt8](AssetImageFixtureBuilder.validPNG(width: 4, height: 4))
        // IEND's 4-byte CRC-32 is unconditionally the file's last 4 bytes.
        bytes[bytes.count - 1] ^= 0xFF

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("A single trailing byte appended after a real PNG's terminal IEND chunk is rejected")
    func trailingByteAfterPNGIENDRejected() throws {
        var bytes = AssetImageFixtureBuilder.validPNG(width: 4, height: 4)
        bytes.append(0x00)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: bytes,
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("A single trailing byte appended after a real JPEG's terminal EOI marker is rejected")
    func trailingByteAfterJPEGEOIRejected() throws {
        var bytes = AssetImageFixtureBuilder.validJPEG(width: 4, height: 4)
        bytes.append(0x00)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: bytes,
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: limits
            )
        }
    }
}
