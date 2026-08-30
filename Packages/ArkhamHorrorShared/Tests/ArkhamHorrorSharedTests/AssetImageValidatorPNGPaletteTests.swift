@testable import ArkhamHorrorShared
import Foundation
import ImageIO
import Testing

/// Coverage for ``AssetImageValidator``'s `PLTE` chunk semantics
/// (`AssetImageValidator+PNGStructure.swift`'s `validatePLTEChunk`). `tRNS`
/// coverage lives in the sibling
/// `AssetImageValidatorPNGTransparencyTests.swift`, split out purely to
/// stay under SwiftLint's `file_length`; it shares this file's
/// chunk-splicing/fixture helpers below (widened from `private` so both
/// files can call them). Every mutation here starts from a genuinely
/// ImageIO-produced, otherwise-valid PNG fixture and splices in a
/// CRC-correct `PLTE` chunk at a specific byte offset -- exercising the
/// exact same production `AssetImageValidator.validate` entry point every
/// other suite in this package uses, never an isolated helper called in
/// unrealistic isolation. Several of these mutated files remain fully
/// decodable by ImageIO itself (grayscale/grayscale+alpha PNGs silently
/// tolerate a spec-forbidden `PLTE` companion chunk, since decoders
/// simply ignore color information they don't need) -- proving this
/// pipeline's own structural rejection catches spec violations a "does
/// it decode" check alone would let straight through to cache.
extension AssetImageValidatorTests {
    /// Builds a single, well-formed, CRC-valid PNG chunk of `type`
    /// carrying `payload`, exactly as ``AssetImageValidator``'s own chunk
    /// walk expects. A duplicate of ``AssetImageValidatorPNGTests``'s
    /// identical helper (Swift's per-file `private` visibility for
    /// same-type extensions means it cannot be shared with that file
    /// without widening its access level there too); shared with this
    /// file's own sibling `AssetImageValidatorPNGTransparencyTests.swift`
    /// instead, via `internal` (default) access.
    func paletteChunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var bytes = [UInt8](withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        let typeAndPayload = Array(type.utf8) + payload
        bytes += typeAndPayload
        let crc = CRC32.checksum(Data(typeAndPayload))
        bytes += withUnsafeBytes(of: crc.bigEndian, Array.init)
        return bytes
    }

    private func paletteReadUInt32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    /// The full byte range (length field through CRC, inclusive) of the
    /// first chunk of `type` in `bytes`.
    private func paletteChunkRange(_ bytes: [UInt8], type: String) throws -> Range<Int> {
        let tag: [UInt8] = Array(type.utf8)
        guard let tagRange = bytes.firstRange(of: tag) else {
            Issue.record("Fixture must contain a \(type) chunk")
            throw AssetError.malformedImageData
        }
        let chunkStart = tagRange.lowerBound - 4
        let length = Int(paletteReadUInt32BE(bytes, at: chunkStart))
        let chunkEnd = chunkStart + 4 + 4 + length + 4
        return chunkStart ..< chunkEnd
    }

    /// Splices `newChunk`'s bytes immediately before the first chunk of
    /// `type` in `bytes` (used throughout to insert a `PLTE`/`tRNS`
    /// chunk at a specific, spec-relevant position -- before the first
    /// `IDAT`, or after a just-inserted `PLTE`).
    func paletteSplice(
        _ newChunk: [UInt8], before type: String, in bytes: [UInt8]
    ) throws -> [UInt8] {
        let range = try paletteChunkRange(bytes, type: type)
        var mutated = Array(bytes[..<range.lowerBound])
        mutated += newChunk
        mutated += Array(bytes[range.lowerBound...])
        return mutated
    }

    /// Splices `newChunk`'s bytes immediately after the first full chunk
    /// of `type` in `bytes`.
    func paletteSplice(
        _ newChunk: [UInt8], after type: String, in bytes: [UInt8]
    ) throws -> [UInt8] {
        let range = try paletteChunkRange(bytes, type: type)
        var mutated = Array(bytes[..<range.upperBound])
        mutated += newChunk
        mutated += Array(bytes[range.upperBound...])
        return mutated
    }

    /// A minimal, hand-assembled, structurally-complete (signature,
    /// `IHDR`, optional `PLTE`, one `IDAT` with an arbitrary payload,
    /// `IEND`) indexed-color (`colorType == 3`) PNG. The `IDAT` payload
    /// is deliberately *not* a valid zlib stream: every test that uses
    /// this builder is proving a rejection that
    /// ``AssetImageValidator/validatePNGStructure(_:colorInfo:)`` raises
    /// while still walking chunks, strictly before
    /// ``AssetImageValidator/validateExactPNGInflation(idatPayload:rowByteCount:rowCount:)``
    /// would ever get a chance to inspect that payload's own validity --
    /// so its exact bytes are irrelevant to what these tests exercise.
    func indexedColorPNG(width: Int = 2, height: Int = 2, includePLTE: Bool) -> [UInt8] {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var ihdrPayload = [UInt8](withUnsafeBytes(of: UInt32(width).bigEndian, Array.init))
        ihdrPayload += withUnsafeBytes(of: UInt32(height).bigEndian, Array.init)
        ihdrPayload += [8, 3, 0, 0, 0] // bitDepth=8, colorType=3 (indexed), CM/FM/interlace=0
        bytes += paletteChunk("IHDR", ihdrPayload)
        if includePLTE {
            bytes += paletteChunk("PLTE", [0, 0, 0, 255, 255, 255])
        }
        bytes += paletteChunk("IDAT", [0, 0, 0, 0])
        bytes += paletteChunk("IEND", [])
        return bytes
    }

    // MARK: - PLTE

    @Test(
        """
        A real grayscale+alpha (colorType 4) PNG with a spliced-in, CRC-correct PLTE chunk is \
        rejected, even though ImageIO itself still successfully decodes the mutated bytes
        """
    )
    func plteForbiddenForGrayscaleAlphaRejectedDespiteImageIODecodingIt() throws {
        let (fixture, colorInfo) = try grayscaleAlphaFixture(width: 6, height: 6)
        #expect(colorInfo.colorType == 4)
        let plte = paletteChunk("PLTE", [10, 20, 30])
        let mutated = try paletteSplice(plte, before: "IDAT", in: Array(fixture))

        // Prove the mutation is still real, decodable image data -- a
        // "does ImageIO decode it" check alone would accept this file.
        let source = CGImageSourceCreateWithData(Data(mutated) as CFData, nil)
        #expect(source != nil)
        if let source {
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
        }

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(mutated),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("A real pure-grayscale (colorType 0) PNG with a spliced-in PLTE chunk is rejected")
    func plteForbiddenForGrayscaleRejected() throws {
        let (fixture, colorInfo) = try grayscaleFixture(width: 6, height: 6)
        #expect(colorInfo.colorType == 0)
        let plte = paletteChunk("PLTE", [10, 20, 30])
        let mutated = try paletteSplice(plte, before: "IDAT", in: Array(fixture))

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(mutated),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("A real PNG with two spliced-in PLTE chunks (duplicate) is rejected")
    func duplicatePLTERejected() throws {
        let full = [UInt8](AssetImageFixtureBuilder.validPNG(width: 6, height: 6))
        let plte = paletteChunk("PLTE", [10, 20, 30])
        var mutated = try paletteSplice(plte, before: "IDAT", in: full)
        mutated = try paletteSplice(plte, before: "IDAT", in: mutated)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(mutated),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("A real PNG with a PLTE chunk spliced in after its first IDAT chunk is rejected")
    func plteAfterIDATRejected() throws {
        let full = [UInt8](AssetImageFixtureBuilder.validPNG(width: 6, height: 6))
        let plte = paletteChunk("PLTE", [10, 20, 30])
        let mutated = try paletteSplice(plte, after: "IDAT", in: full)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(mutated),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("A PLTE chunk whose payload length is not a multiple of 3 bytes is rejected")
    func plteNonMultipleOf3LengthRejected() throws {
        let full = [UInt8](AssetImageFixtureBuilder.validPNG(width: 6, height: 6))
        let plte = paletteChunk("PLTE", [10, 20, 30, 40])
        let mutated = try paletteSplice(plte, before: "IDAT", in: full)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(mutated),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("An empty (zero-entry) PLTE chunk is rejected")
    func plteZeroEntriesRejected() throws {
        let full = [UInt8](AssetImageFixtureBuilder.validPNG(width: 6, height: 6))
        let plte = paletteChunk("PLTE", [])
        let mutated = try paletteSplice(plte, before: "IDAT", in: full)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(mutated),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("A PLTE chunk with 257 entries (exceeding the 256-entry ceiling) is rejected")
    func plteTooManyEntriesRejected() throws {
        let full = [UInt8](AssetImageFixtureBuilder.validPNG(width: 6, height: 6))
        var payload = [UInt8]()
        for entryIndex in 0 ..< 257 {
            payload += [
                UInt8(entryIndex % 256), UInt8(entryIndex % 256), UInt8(entryIndex % 256),
            ]
        }
        let plte = paletteChunk("PLTE", payload)
        let mutated = try paletteSplice(plte, before: "IDAT", in: full)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(mutated),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test("A colorType 3 (indexed) PNG with no PLTE chunk at all is rejected")
    func plteRequiredForIndexedMissingRejected() throws {
        let bytes = indexedColorPNG(includePLTE: false)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: Data(bytes),
                declaredContentType: nil,
                expectedFormat: .png,
                limits: limits
            )
        }
    }

    @Test(
        """
        A colorType 3 (indexed) PNG with a well-formed PLTE chunk passes the chunk-order/PLTE/\
        tRNS structural walk (the container-level check this suite exercises), independent of \
        whether its IDAT payload happens to be valid zlib
        """
    )
    func plteSatisfiesIndexedRequirement() throws {
        let bytes = indexedColorPNG(includePLTE: true)
        let colorInfo = try AssetImageValidator.parsePNGColorInfo(Data(bytes))

        let idatPayload = try AssetImageValidator.validatePNGStructure(
            Data(bytes), colorInfo: colorInfo
        )
        #expect(!idatPayload.isEmpty)
    }

    // MARK: - Real grayscale fixture builders

    /// A genuine, ImageIO-encoded pure-grayscale (no alpha, `colorType ==
    /// 0`) PNG, built the same way ``AssetImageFixtureBuilder``'s own
    /// RGBA fixtures are (a filled `CGContext`, encoded via
    /// `CGImageDestinationCreateWithData`) but with `CGColorSpaceCreateDeviceGray()`
    /// and no alpha channel, which ImageIO's PNG encoder emits as
    /// `colorType == 0`.
    func grayscaleFixture(
        width: Int, height: Int
    ) throws -> (Data, AssetImageValidator.PNGColorInfo) {
        let data = try AssetImageValidatorPNGPaletteTests.renderGray(
            width: width, height: height, alpha: false
        )
        return try (data, AssetImageValidator.parsePNGColorInfo(data))
    }

    /// The grayscale+alpha (`colorType == 4`) counterpart of
    /// ``grayscaleFixture(width:height:)``.
    func grayscaleAlphaFixture(
        width: Int, height: Int
    ) throws -> (Data, AssetImageValidator.PNGColorInfo) {
        let data = try AssetImageValidatorPNGPaletteTests.renderGray(
            width: width, height: height, alpha: true
        )
        return try (data, AssetImageValidator.parsePNGColorInfo(data))
    }
}

/// A free-standing namespace for the grayscale PNG renderer used above --
/// kept outside the `AssetImageValidatorTests` extension purely so its
/// `CGContext`/`CGImageDestination` plumbing doesn't need to live inline
/// in every call site.
enum AssetImageValidatorPNGPaletteTests {
    static func renderGray(width: Int, height: Int, alpha: Bool) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = alpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.none.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw AssetError.malformedImageData
        }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else {
            throw AssetError.malformedImageData
        }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, "public.png" as CFString, 1, nil
            )
        else {
            throw AssetError.malformedImageData
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AssetError.malformedImageData
        }
        return data as Data
    }
}
