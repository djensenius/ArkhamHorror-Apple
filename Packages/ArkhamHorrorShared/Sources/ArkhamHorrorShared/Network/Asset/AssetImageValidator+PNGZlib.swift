import Foundation

/// `IHDR`-derived exact expected-byte-count math for a PNG's decompressed
/// (filtered scanline) payload, beyond ``validatePNGStructure(_:)``'s own
/// container-level (chunk length/CRC/ordering) checks.
///
/// The actual zlib/DEFLATE decompression and exact-byte-count enforcement
/// this math feeds into lives in
/// `AssetImageValidator+PNGZlibStreaming.swift`, split into its own file
/// purely to keep this file within this project's configured
/// `SwiftLint` file-length limit.
extension AssetImageValidator {
    /// The subset of `IHDR` fields needed to compute the exact expected
    /// decompressed (filtered scanline) byte count, beyond the
    /// width/height ``parsePNGDimensions(_:)`` already extracts.
    struct PNGColorInfo: Equatable {
        let bitDepth: UInt8
        let colorType: UInt8
        let interlaceMethod: UInt8
    }

    /// Reads the bit-depth, color-type, and interlace-method fields from
    /// a PNG's `IHDR` chunk. Only ever called after ``parsePNGDimensions(_:)``
    /// has already confirmed `data` is at least 33 bytes with a
    /// well-formed, 13-byte `IHDR` chunk at the expected fixed offset, so
    /// the same fixed byte offsets are safe to read directly here.
    static func parsePNGColorInfo(_ data: Data) throws -> PNGColorInfo {
        guard data.count >= 29 else { throw AssetError.malformedImageData }
        let base = data.startIndex
        // Per the PNG spec, `IHDR`'s compression method (byte 26) and
        // filter method (byte 27) are each defined to have exactly one
        // valid value (0: deflate/inflate; 0: adaptive filtering per
        // scanline). Any other value means the file is not a spec-valid
        // PNG, even if every other field looks plausible -- reject it
        // here rather than letting a structurally-invalid IHDR reach
        // ImageIO decode.
        guard data[base + 26] == 0 else { throw AssetError.malformedImageData }
        guard data[base + 27] == 0 else { throw AssetError.malformedImageData }
        return PNGColorInfo(
            bitDepth: data[base + 24],
            colorType: data[base + 25],
            interlaceMethod: data[base + 28]
        )
    }

    /// Maps an `IHDR` color-type byte to its channel count, throwing for
    /// any value outside the five PNG-specification-defined color types.
    private static func pngChannelCount(for colorType: UInt8) throws -> Int {
        switch colorType {
        case 0: return 1 // grayscale
        case 2: return 3 // truecolor
        case 3: return 1 // indexed
        case 4: return 2 // grayscale + alpha
        case 6: return 4 // truecolor + alpha
        default: throw AssetError.malformedImageData
        }
    }

    /// The PNG specification restricts which `bitDepth` values are valid
    /// for each `colorType`, beyond the five bit depths (1/2/4/8/16) that
    /// are valid for *some* color type: indexed-color (3) is capped at 8
    /// bits (a palette index can't need 16 bits), while truecolor (2),
    /// grayscale+alpha (4), and truecolor+alpha (6) all require at least
    /// one full byte per channel (8 or 16) since sub-byte packing is only
    /// defined for single-channel images. Only grayscale (0) permits the
    /// full 1/2/4/8/16 range. Accepting an out-of-range combination here
    /// would let a structurally-invalid IHDR reach ImageIO decode.
    private static func pngAllowedBitDepths(for colorType: UInt8) throws -> Set<UInt8> {
        switch colorType {
        case 0: return [1, 2, 4, 8, 16] // grayscale
        case 2, 4, 6: return [8, 16] // truecolor, grayscale+alpha, truecolor+alpha
        case 3: return [1, 2, 4, 8] // indexed
        default: throw AssetError.malformedImageData
        }
    }

    /// The exact number of decompressed bytes a single non-interlaced
    /// scanline must occupy: one leading filter-type byte plus
    /// `ceil(width * channels * bitDepth / 8)` bytes of actual pixel
    /// data. Exposed separately from ``expectedPNGScanlineByteCount(width:height:colorInfo:)``
    /// (which multiplies this by `height`) because the *streaming*
    /// inflation validator needs this single-row bound on its own: this
    /// pipeline's own configured `maxDimension` (8192) already caps a
    /// single row at a few tens of kilobytes at most (8192 pixels × 4
    /// channels × 16-bit depth ÷ 8 + 1 ≈ 65 KiB), which is what makes it
    /// safe to use as a small, fixed-size scratch buffer regardless of
    /// the image's total pixel count -- unlike the *total* decompressed
    /// byte count, which scales with `height` and can reach hundreds of
    /// megabytes at this pipeline's own configured pixel-count limit.
    ///
    /// Adam7-interlaced PNGs (`interlaceMethod != 0`) split their data
    /// across seven differently sized sub-images and are deliberately
    /// rejected as unsupported rather than exactly validated --
    /// ImageIO-generated fixtures (this pipeline's own fixture builder,
    /// and every real asset this cache expects) never use interlacing,
    /// and getting Adam7's per-pass dimension arithmetic wrong would be
    /// worse than simply not supporting it.
    static func pngRowByteCount(width: Int, colorInfo: PNGColorInfo) throws -> Int {
        guard colorInfo.interlaceMethod == 0 else {
            throw AssetError.malformedImageData
        }
        let channels = try pngChannelCount(for: colorInfo.colorType)
        let allowedBitDepths = try pngAllowedBitDepths(for: colorInfo.colorType)
        guard allowedBitDepths.contains(colorInfo.bitDepth) else {
            throw AssetError.malformedImageData
        }
        let bitsPerPixel = channels * Int(colorInfo.bitDepth)
        let (bitsPerRow, bitsOverflowed) = width.multipliedReportingOverflow(by: bitsPerPixel)
        guard !bitsOverflowed else { throw AssetError.malformedImageData }
        let bytesPerScanline = (bitsPerRow + 7) / 8
        let (rowLength, rowOverflowed) = bytesPerScanline.addingReportingOverflow(1)
        guard !rowOverflowed else { throw AssetError.malformedImageData }
        return rowLength
    }

    /// The exact total number of decompressed (filtered scanline) bytes
    /// a non-interlaced PNG with the given dimensions and color info
    /// must decompress to, across every one of its `height` scanlines.
    static func expectedPNGScanlineByteCount(
        width: Int,
        height: Int,
        colorInfo: PNGColorInfo
    ) throws -> Int {
        let rowLength = try pngRowByteCount(width: width, colorInfo: colorInfo)
        let (total, totalOverflowed) = rowLength.multipliedReportingOverflow(by: height)
        guard !totalOverflowed else { throw AssetError.malformedImageData }
        return total
    }
}
