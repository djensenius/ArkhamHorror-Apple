@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AssetImageValidatorTests {
    // MARK: - AVIF trailing bytes / multi-frame rejection

    @Test(
        """
        A real, complete AVIF with 1-7 trailing bytes appended after its last top-level box \
        is rejected, not silently accepted as "no more boxes to read"
        """
    )
    func avifTrailingBytesRejected() throws {
        let full = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
        for trailingByteCount in 1 ... 7 {
            var mutated = full
            mutated.append(contentsOf: [UInt8](repeating: 0, count: trailingByteCount))
            #expect(
                throws: AssetError.malformedImageData,
                "trailing byte count \(trailingByteCount)"
            ) {
                _ = try AssetImageValidator.validate(
                    data: mutated,
                    declaredContentType: nil,
                    expectedFormat: .avif,
                    limits: limits
                )
            }
        }
    }

    @Test("The complete, untruncated real AVIF fixture (no trailing bytes) still validates")
    func avifWithoutTrailingBytesStillValidates() throws {
        let data = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
        let metadata = try AssetImageValidator.validate(
            data: data,
            declaredContentType: nil,
            expectedFormat: .avif,
            limits: limits
        )
        #expect(metadata.width == 4)
        #expect(metadata.height == 4)
    }

    // MARK: - Multi-frame rejection at the shared decode choke point

    @Test(
        """
        A genuinely two-frame PNG (CGImageSourceGetCount == 2) is rejected by the shared \
        decoder, which only ever decodes and publishes a single still image
        """
    )
    func twoFramePNGRejectedByDecoder() throws {
        let data = AssetImageFixtureBuilder.twoFramePNG(width: 4, height: 4)
        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageDecoder.decode(data)
        }
    }

    @Test("A genuine single-frame PNG still decodes successfully through the shared decoder")
    func singleFramePNGStillDecodes() throws {
        let data = AssetImageFixtureBuilder.validPNG(width: 4, height: 4)
        let image = try AssetImageDecoder.decode(data)
        #expect(image.width == 4)
        #expect(image.height == 4)
    }
}
