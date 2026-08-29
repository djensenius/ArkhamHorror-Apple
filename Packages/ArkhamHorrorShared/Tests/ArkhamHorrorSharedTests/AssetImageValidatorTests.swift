@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("AssetImageValidator")
struct AssetImageValidatorTests {
    private let limits = AssetCacheLimits(
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

    @Test("A JPEG truncated mid-marker-walk is rejected as malformed, not a crash")
    func truncatedJPEGRejected() throws {
        // SOI + an APP0 marker whose length bytes never arrive: long enough
        // to clear the SOI signature check, but truncated inside the
        // marker-segment walk (not the initial 4-byte signature check).
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: data,
                declaredContentType: nil,
                expectedFormat: .jpeg,
                limits: self.limits
            )
        }
    }

    @Test(
        """
        A JPEG SOF segment whose declared length is too short for its own \
        precision/height/width fields is rejected, even though plausible \
        extra bytes happen to follow it in the buffer
        """
    )
    func jpegSOFSegmentDeclaredLengthTooShortRejected() throws {
        var bytes: [UInt8] = [0xFF, 0xD8] // SOI
        bytes += [0xFF, 0xC0] // SOF0 marker
        // A declared segment length of 4: after its own 2 length bytes,
        // only 2 payload bytes remain — nowhere near the 5 bytes needed
        // for precision (1) + height (2) + width (2).
        bytes += [0x00, 0x04]
        bytes += [0x08, 0x00]
        // Bytes that a naive "does this stay within the whole buffer"
        // check (ignoring the segment's own declared length) could
        // mistake for the rest of a plausible height/width, if the
        // segment-length guard were absent.
        bytes += [0x00, 0x10, 0x00, 0x20, 0x00, 0x30]
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

extension AssetImageValidatorTests {
    // MARK: - Dimension / pixel-count limits (via the real parsers)

    @Test("A real PNG whose dimensions exceed the configured maximum per-side limit is rejected")
    func pngOversizedDimensionRejected() throws {
        let tinyLimits = AssetCacheLimits(
            maxEncodedBytes: 20 * 1024 * 1024,
            maxDimension: 4,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1024,
            diskBudgetBytes: 1024
        )
        let data = AssetImageFixtureBuilder.validPNG(width: 6, height: 4)
        #expect(throws: AssetError.dimensionTooLarge) {
            _ = try AssetImageValidator.validate(
                data: data,
                declaredContentType: nil,
                expectedFormat: .png,
                limits: tinyLimits
            )
        }
    }

    @Test(
        "A real PNG whose pixel count exceeds the configured max is rejected, dimensions in range"
    )
    func pngOversizedPixelCountRejected() throws {
        let tinyLimits = AssetCacheLimits(
            maxEncodedBytes: 20 * 1024 * 1024,
            maxDimension: 8192,
            maxPixelCount: 20,
            memoryBudgetBytes: 1024,
            diskBudgetBytes: 1024
        )
        let data = AssetImageFixtureBuilder.validPNG(width: 6, height: 6)
        #expect(throws: AssetError.pixelCountTooLarge) {
            _ = try AssetImageValidator.validate(
                data: data,
                declaredContentType: nil,
                expectedFormat: .png,
                limits: tinyLimits
            )
        }
    }

    // MARK: - `validateDimensions` overflow safety (adversarial `Int`s, format-independent)

    @Test(
        "A width/height pair whose product would overflow Int64 is rejected as pixelCountTooLarge"
    )
    func overflowingDimensionProductRejected() throws {
        let permissiveLimits = AssetCacheLimits(
            maxEncodedBytes: 20 * 1024 * 1024,
            maxDimension: Int.max,
            maxPixelCount: Int.max,
            memoryBudgetBytes: 1024,
            diskBudgetBytes: 1024
        )
        #expect(throws: AssetError.pixelCountTooLarge) {
            try AssetImageValidator.validateDimensions(
                width: Int.max,
                height: 2,
                limits: permissiveLimits
            )
        }
    }

    @Test(
        "Two large dimensions whose Int64 product genuinely overflows are rejected, not oversized"
    )
    func overflowingLargeDimensionsRejected() throws {
        // Deliberately larger than any real parser could ever produce
        // (PNG/AVIF cap each side at Int32.max, JPEG at UInt16.max), and
        // large enough that the *product* overflows Int64 (unlike
        // Int32.max × Int32.max, which is ~4.6×10^18 and still fits in an
        // Int64), to exercise the overflow guard itself rather than a
        // plain oversized-value check.
        let permissiveLimits = AssetCacheLimits(
            maxEncodedBytes: 20 * 1024 * 1024,
            maxDimension: Int.max,
            maxPixelCount: Int.max,
            memoryBudgetBytes: 1024,
            diskBudgetBytes: 1024
        )
        #expect(throws: AssetError.pixelCountTooLarge) {
            try AssetImageValidator.validateDimensions(
                width: 4_000_000_000,
                height: 4_000_000_000,
                limits: permissiveLimits
            )
        }
    }

    @Test("Zero or negative dimensions are rejected as malformed rather than accepted or trapping")
    func zeroOrNegativeDimensionsRejected() throws {
        #expect(throws: AssetError.malformedImageData) {
            try AssetImageValidator.validateDimensions(width: 0, height: 10, limits: self.limits)
        }
        #expect(throws: AssetError.malformedImageData) {
            try AssetImageValidator.validateDimensions(width: 10, height: -1, limits: self.limits)
        }
    }

    @Test(
        "A width/height pair exactly at the configured maximum pixel count is accepted (inclusive)"
    )
    func exactPixelCountBoundaryAccepted() throws {
        let exactLimits = AssetCacheLimits(
            maxEncodedBytes: 20 * 1024 * 1024,
            maxDimension: 100,
            maxPixelCount: 100,
            memoryBudgetBytes: 1024,
            diskBudgetBytes: 1024
        )
        try AssetImageValidator.validateDimensions(width: 10, height: 10, limits: exactLimits)
    }
}
