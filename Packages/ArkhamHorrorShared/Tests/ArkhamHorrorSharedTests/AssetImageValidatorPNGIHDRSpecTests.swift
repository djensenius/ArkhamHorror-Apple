@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for `IHDR`-level PNG-specification-validity checks that go
/// beyond ``AssetImageValidatorPNGZlibTests``'s own exact-inflation-byte-
/// count math: `parsePNGColorInfo(_:)`'s compression-method/filter-method
/// byte validation, and `pngRowByteCount(width:colorInfo:)`'s per-
/// `colorType` bit-depth restrictions (not every one of the five PNG bit
/// depths is valid for every color type). Split into its own file purely
/// to keep ``AssetImageValidatorPNGZlibTests`` within this project's
/// configured `SwiftLint` `type_body_length` limit.
@Suite("AssetImageValidator PNG IHDR spec-validity")
struct AssetImageValidatorPNGIHDRSpecTests {
    @Test(
        """
        An IHDR whose compression-method byte is nonzero (spec-invalid: the only defined \
        PNG compression method is 0/deflate) is rejected by parsePNGColorInfo rather than \
        silently accepted alongside a plausible bit depth/color type
        """
    )
    func pngWithNonZeroCompressionMethodRejected() throws {
        var png = AssetImageFixtureBuilder.validPNG(width: 4, height: 4)
        // IHDR's fixed layout after the 8-byte signature and 8-byte
        // chunk length/type header is: width(4) height(4) bitDepth(1)
        // colorType(1) compressionMethod(1) filterMethod(1)
        // interlaceMethod(1) -- so byte offset 26 is compressionMethod.
        png[png.startIndex + 26] = 1
        #expect(throws: AssetError.self) {
            _ = try AssetImageValidator.parsePNGColorInfo(png)
        }
    }

    @Test(
        """
        An IHDR whose filter-method byte is nonzero (spec-invalid: the only defined PNG \
        filter method is 0/adaptive-per-scanline) is rejected by parsePNGColorInfo rather \
        than silently accepted alongside a plausible bit depth/color type
        """
    )
    func pngWithNonZeroFilterMethodRejected() throws {
        var png = AssetImageFixtureBuilder.validPNG(width: 4, height: 4)
        png[png.startIndex + 27] = 1
        #expect(throws: AssetError.self) {
            _ = try AssetImageValidator.parsePNGColorInfo(png)
        }
    }

    @Test(
        """
        A real, untampered PNG's own compression/filter method bytes (both 0, produced by \
        ImageIO) still parse successfully -- proving the new IHDR byte checks don't reject \
        genuinely valid PNGs
        """
    )
    func realPNGCompressionAndFilterMethodBytesAccepted() throws {
        let png = AssetImageFixtureBuilder.validPNG(width: 4, height: 4)
        #expect(png[png.startIndex + 26] == 0)
        #expect(png[png.startIndex + 27] == 0)
        _ = try AssetImageValidator.parsePNGColorInfo(png)
    }

    @Test(
        """
        Indexed-color (palette, colorType 3) at 16-bit depth is spec-invalid -- a palette \
        index never needs more than 8 bits -- and must be rejected rather than silently \
        accepted merely because 16 is one of the five bit depths valid for *some* color type
        """
    )
    func indexedColorAt16BitDepthRejected() throws {
        let colorInfo = AssetImageValidator.PNGColorInfo(
            bitDepth: 16,
            colorType: 3,
            interlaceMethod: 0
        )
        #expect(throws: AssetError.self) {
            _ = try AssetImageValidator.pngRowByteCount(width: 4, colorInfo: colorInfo)
        }
    }

    @Test(
        """
        Truecolor (colorType 2) at a sub-byte bit depth (e.g. 4) is spec-invalid -- \
        truecolor/alpha color types require a full byte or more per channel -- and must be \
        rejected rather than silently accepted merely because 4 is one of the five bit \
        depths valid for *some* color type
        """
    )
    func truecolorAtSubByteBitDepthRejected() throws {
        let colorInfo = AssetImageValidator.PNGColorInfo(
            bitDepth: 4,
            colorType: 2,
            interlaceMethod: 0
        )
        #expect(throws: AssetError.self) {
            _ = try AssetImageValidator.pngRowByteCount(width: 4, colorInfo: colorInfo)
        }
    }

    @Test(
        "Grayscale (colorType 0) still permits every one of the five spec-valid bit depths"
    )
    func grayscalePermitsAllFiveBitDepths() throws {
        for bitDepth: UInt8 in [1, 2, 4, 8, 16] {
            let colorInfo = AssetImageValidator.PNGColorInfo(
                bitDepth: bitDepth,
                colorType: 0,
                interlaceMethod: 0
            )
            _ = try AssetImageValidator.pngRowByteCount(width: 4, colorInfo: colorInfo)
        }
    }
}
