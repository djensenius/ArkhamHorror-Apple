@testable import ArkhamHorrorShared
import Foundation
import ImageIO
import Testing

/// `tRNS` chunk semantics coverage, split out from
/// `AssetImageValidatorPNGPaletteTests.swift` (which covers `PLTE` and
/// shares its chunk-splicing/fixture helpers with this file) purely to
/// stay under SwiftLint's `file_length`. See that file's own top-level
/// doc comment for the shared rationale behind every mutation here
/// starting from a genuinely ImageIO-produced, otherwise-valid PNG
/// fixture and going through the exact same production
/// `AssetImageValidator.validate` entry point every other suite in this
/// package uses.
extension AssetImageValidatorTests {
    @Test(
        """
        A real truecolor+alpha (colorType 6) PNG -- which already carries a full alpha channel \
        -- with a spliced-in tRNS chunk is rejected
        """
    )
    func trnsForbiddenForFullAlphaColorTypeRejected() throws {
        let full = [UInt8](AssetImageFixtureBuilder.validPNG(width: 6, height: 6))
        let trns = paletteChunk("tRNS", [0, 0, 0, 0, 0, 0])
        let mutated = try paletteSplice(trns, before: "IDAT", in: full)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(mutated),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test(
        """
        A real pure-grayscale (colorType 0) PNG with a spliced-in, correctly-sized (2-byte) tRNS \
        chunk still validates, decodes, and reports its true dimensions
        """
    )
    func trnsCorrectLengthGrayscaleAccepted() throws {
        let (fixture, _) = try grayscaleFixture(width: 6, height: 6)
        let trns = paletteChunk("tRNS", [0, 128])
        let mutated = try paletteSplice(trns, before: "IDAT", in: Array(fixture))

        let metadata = try AssetImageValidator.validate(
            data: Data(mutated),
            declaredContentType: nil,
            expectedFormat: .png,
            limits: limits
        )
        #expect(metadata.width == 6)
        #expect(metadata.height == 6)
    }

    @Test("A tRNS chunk with a wrong (non-2-byte) length for a grayscale PNG is rejected")
    func trnsWrongLengthForGrayscaleRejected() throws {
        let (fixture, _) = try grayscaleFixture(width: 6, height: 6)
        let trns = paletteChunk("tRNS", [0, 128, 0])
        let mutated = try paletteSplice(trns, before: "IDAT", in: Array(fixture))

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(mutated),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("A real PNG with two spliced-in tRNS chunks (duplicate) is rejected")
    func duplicateTRNSRejected() throws {
        let (fixture, _) = try grayscaleFixture(width: 6, height: 6)
        let trns = paletteChunk("tRNS", [0, 128])
        var mutated = try paletteSplice(trns, before: "IDAT", in: Array(fixture))
        mutated = try paletteSplice(trns, before: "IDAT", in: mutated)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(mutated),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("A tRNS chunk appearing before PLTE (for an indexed PNG) is rejected")
    func trnsBeforePLTEForIndexedRejected() throws {
        // `indexedColorPNG(includePLTE: true)` already places `PLTE`
        // before `IDAT`; splicing a `tRNS` chunk immediately before that
        // same `PLTE` chunk reorders them to `tRNS`, `PLTE`, `IDAT` --
        // the specification-forbidden order for indexed color, since a
        // `tRNS` entry only has meaning once `PLTE`'s own entries are
        // known.
        var bytes = indexedColorPNG(includePLTE: true)
        let trns = paletteChunk("tRNS", [0])
        bytes = try paletteSplice(trns, before: "PLTE", in: bytes)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("A tRNS chunk longer than its preceding PLTE's own entry count is rejected")
    func trnsExceedsPaletteEntryCountRejected() throws {
        // `indexedColorPNG(includePLTE: true)` plants a 2-entry PLTE;
        // a 3-byte tRNS (one byte per entry) exceeds that.
        var bytes = indexedColorPNG(includePLTE: true)
        let trns = paletteChunk("tRNS", [255, 255, 255])
        bytes = try paletteSplice(trns, after: "PLTE", in: bytes)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("A tRNS chunk no longer than its preceding PLTE's own entry count is accepted")
    func trnsWithinPaletteEntryCountStructurallyAccepted() throws {
        var bytes = indexedColorPNG(includePLTE: true)
        let trns = paletteChunk("tRNS", [255])
        bytes = try paletteSplice(trns, after: "PLTE", in: bytes)
        let colorInfo = try AssetImageValidator.parsePNGColorInfo(Data(bytes))

        // As with `plteSatisfiesIndexedRequirement`: the hand-built IDAT
        // is not valid zlib, so this only proves the chunk-order/PLTE/
        // tRNS walk itself accepts the file (the direct
        // `validatePNGStructure` call below succeeds and returns the raw
        // IDAT payload; only the full pipeline's later inflation step
        // would go on to reject it).
        let idatPayload = try AssetImageValidator.validatePNGStructure(
            Data(bytes), colorInfo: colorInfo
        )
        #expect(!idatPayload.isEmpty)
    }

    @Test("A real PNG with a tRNS chunk spliced in after its first IDAT chunk is rejected")
    func trnsAfterIDATRejected() throws {
        let (fixture, _) = try grayscaleFixture(width: 6, height: 6)
        let trns = paletteChunk("tRNS", [0, 128])
        let mutated = try paletteSplice(trns, after: "IDAT", in: Array(fixture))

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(mutated),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }
}
