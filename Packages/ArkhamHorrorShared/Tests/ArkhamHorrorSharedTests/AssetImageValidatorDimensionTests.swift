@testable import ArkhamHorrorShared
import Foundation
import Testing

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
