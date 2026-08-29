@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("AssetImageValidator")
struct AssetImageValidatorTests {
    /// Not `private`: shared with `AssetImageValidatorDimensionTests.swift`,
    /// an extension of this struct split into a separate file to stay
    /// under SwiftLint's `file_length` limit.
    let limits = AssetCacheLimits(
        maxEncodedBytes: 20 * 1024 * 1024,
        maxDimension: 8192,
        maxPixelCount: 32_000_000,
        memoryBudgetBytes: 1024,
        diskBudgetBytes: 1024
    )

    // MARK: - Happy path, per format

    @Test("A real PNG with a matching Content-Type validates and reports its true dimensions")
    func validPNGAccepted() throws {
        let data = AssetImageFixtureBuilder.validPNG(width: 6, height: 9)
        let metadata = try AssetImageValidator.validate(
            data: data,
            declaredContentType: "image/png",
            expectedFormat: .png,
            limits: limits
        )
        #expect(metadata.format == .png)
        #expect(metadata.width == 6)
        #expect(metadata.height == 9)
    }

    @Test("A real JPEG with a matching Content-Type (including a charset parameter) validates")
    func validJPEGAcceptedWithContentTypeParameter() throws {
        let data = AssetImageFixtureBuilder.validJPEG(width: 12, height: 5)
        let metadata = try AssetImageValidator.validate(
            data: data,
            declaredContentType: "image/jpeg; charset=binary",
            expectedFormat: .jpeg,
            limits: limits
        )
        #expect(metadata.format == .jpeg)
        #expect(metadata.width == 12)
        #expect(metadata.height == 5)
    }

    @Test(
        "A synthetic AVIF shell with no declared Content-Type still validates on magic bytes alone"
    )
    func validAVIFAcceptedWithoutDeclaredContentType() throws {
        let data = AssetImageFixtureBuilder.syntheticAVIF(width: 3, height: 4)
        let metadata = try AssetImageValidator.validate(
            data: data,
            declaredContentType: nil,
            expectedFormat: .avif,
            limits: limits
        )
        #expect(metadata.format == .avif)
        #expect(metadata.width == 3)
        #expect(metadata.height == 4)
    }

    // MARK: - Content-Type mismatch

    @Test(
        "A declared Content-Type not matching the expected format is rejected with valid bytes"
    )
    func contentTypeMismatchRejected() throws {
        let data = AssetImageFixtureBuilder.validPNG()
        #expect(throws: AssetError.contentTypeMismatch) {
            _ = try AssetImageValidator.validate(
                data: data,
                declaredContentType: "image/jpeg",
                expectedFormat: .png,
                limits: self.limits
            )
        }
    }

    @Test("An unrelated Content-Type (e.g. text/html, an interstitial/error page) is rejected")
    func unrelatedContentTypeRejected() throws {
        let data = AssetImageFixtureBuilder.validPNG()
        #expect(throws: AssetError.contentTypeMismatch) {
            _ = try AssetImageValidator.validate(
                data: data,
                declaredContentType: "text/html",
                expectedFormat: .png,
                limits: self.limits
            )
        }
    }

    // MARK: - Signature mismatch

    @Test(
        "Bytes with the wrong signature for the expected format are rejected, matching Content-Type"
    )
    func signatureMismatchRejected() throws {
        let jpegBytes = AssetImageFixtureBuilder.validJPEG()
        #expect(throws: AssetError.signatureMismatch) {
            _ = try AssetImageValidator.validate(
                data: jpegBytes,
                declaredContentType: "image/png",
                expectedFormat: .png,
                limits: self.limits
            )
        }
    }

    @Test("An AVIF ftyp declaring an unrelated brand (not avif/avis) is rejected")
    func avifWrongBrandRejected() throws {
        let data = AssetImageFixtureBuilder.syntheticAVIF(width: 2, height: 2, brand: "heic")
        #expect(throws: AssetError.signatureMismatch) {
            _ = try AssetImageValidator.validate(
                data: data,
                declaredContentType: nil,
                expectedFormat: .avif,
                limits: self.limits
            )
        }
    }

    // MARK: - Malformed / truncated data

    @Test("Empty data is rejected as a signature mismatch, not a crash")
    func emptyDataRejected() throws {
        #expect(throws: AssetError.signatureMismatch) {
            _ = try AssetImageValidator.validate(
                data: Data(),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: self.limits
            )
        }
    }

    @Test("A truncated PNG (valid signature, no IHDR) is rejected as malformed, not a crash")
    func truncatedPNGRejected() throws {
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // The 8-byte signature matches exactly, so this is a truncated PNG
        // (malformed), not a wrong-format file (signature mismatch).
        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: signature,
                declaredContentType: nil,
                expectedFormat: .png,
                limits: self.limits
            )
        }
    }

    @Test("A PNG signature with a single wrong byte is rejected as a signature mismatch")
    func pngWrongSignatureByteRejected() throws {
        // Differs from the real signature only in its final byte, and is
        // otherwise long enough to pass the length check alone — this must
        // still be a signature mismatch, not "malformed", since the bytes
        // never matched the PNG magic in the first place.
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x00]
        bytes += [UInt8](repeating: 0, count: 25)
        #expect(throws: AssetError.signatureMismatch) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("An AVIF ftyp with no following meta box is rejected as malformed, not a crash")
    func avifMissingMetaRejected() throws {
        let data = AssetImageFixtureBuilder.avifMissingMeta()
        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: data,
                declaredContentType: nil,
                expectedFormat: .avif,
                limits: self.limits
            )
        }
    }

    @Test(
        """
        An AVIF ispe box truncated before its height field is rejected, even \
        though plausible-looking height bytes happen to follow it in the \
        buffer
        """
    )
    func avifTruncatedISPERejectedRatherThanReadingTrailingBytes() throws {
        let data = AssetImageFixtureBuilder.syntheticAVIFTruncatedISPE(width: 100)
        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: data,
                declaredContentType: nil,
                expectedFormat: .avif,
                limits: self.limits
            )
        }
    }

    @Test(
        """
        An AVIF child box using the 64-bit extended-size form but truncated before its \
        size64 field is rejected, even though plausible bytes happen to follow it
        """
    )
    func avifTruncatedExtendedSizeBoxRejectedRatherThanReadingTrailingBytes() throws {
        let data = AssetImageFixtureBuilder.syntheticAVIFExtendedSizeBoxTruncated()
        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: data,
                declaredContentType: nil,
                expectedFormat: .avif,
                limits: self.limits
            )
        }
    }

    @Test("A PNG with a non-13 IHDR chunk length is rejected as malformed, not decoded")
    func pngWithWrongIHDRLengthRejected() throws {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        // A declared length of 12 (one byte short of the correct 13) with
        // an otherwise well-formed "IHDR" tag and plausible width/height.
        bytes += [0x00, 0x00, 0x00, 0x0C]
        bytes += Array("IHDR".utf8)
        bytes += [0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04]
        bytes += [UInt8](repeating: 0, count: 21)
        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }
}
