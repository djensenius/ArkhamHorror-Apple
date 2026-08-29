import Foundation

/// Validated, decode-safe metadata extracted from an image response body
/// before any full platform decode is attempted.
struct ValidatedImageMetadata: Sendable, Equatable {
    let format: AssetFormat
    let width: Int
    let height: Int
}

/// Validates a fetched response body against an expected ``AssetFormat``:
/// declared `Content-Type`, magic-byte signature, and safely-parsed pixel
/// dimensions, all before any full image decode is attempted.
///
/// Every check here is pure and allocation-light; none of it depends on
/// platform image decoders (`CGImageSource`, `UIImage`, etc.), so it runs
/// identically across every supported platform and is exercised by plain
/// byte-array fixtures in tests without needing real image decode support.
enum AssetImageValidator {
    /// Validates `data` against `expectedFormat` and `limits`.
    ///
    /// Checks, in order: declared Content-Type (if provided) matches the
    /// expected format's MIME type; the body's magic bytes match the
    /// expected format; the parsed width/height are both positive and at
    /// most `limits.maxDimension`; and the width × height product (computed
    /// with overflow checking) is at most `limits.maxPixelCount`.
    static func validate(
        data: Data,
        declaredContentType: String?,
        expectedFormat: AssetFormat,
        limits: AssetCacheLimits
    ) throws -> ValidatedImageMetadata {
        if let declaredContentType {
            let normalized = declaredContentType
                .split(separator: ";")[0]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard normalized == expectedFormat.mimeType else {
                throw AssetError.contentTypeMismatch
            }
        }

        let dimensions: (width: Int, height: Int) = switch expectedFormat {
        case .png:
            try parsePNGDimensions(data)
        case .jpeg:
            try parseJPEGDimensions(data)
        case .avif:
            try parseAVIFDimensions(data)
        }

        try validateDimensions(width: dimensions.width, height: dimensions.height, limits: limits)
        return ValidatedImageMetadata(
            format: expectedFormat,
            width: dimensions.width,
            height: dimensions.height
        )
    }

    /// Validates a parsed `width`/`height` pair against `limits`, computing
    /// the pixel count with overflow checking rather than a plain `*`.
    ///
    /// Extracted as its own directly testable entry point (not `private`)
    /// so tests can exercise the overflow-safety guard with adversarial
    /// `Int` values directly, independent of any specific image format's
    /// byte-level dimension encoding (which, for every format this
    /// validator parses, already bounds each individual dimension well
    /// below a value that could make the product overflow — this guard
    /// exists as defense-in-depth against that changing, and against any
    /// future caller of this function that does not share those bounds).
    static func validateDimensions(width: Int, height: Int, limits: AssetCacheLimits) throws {
        guard width > 0, height > 0 else {
            throw AssetError.malformedImageData
        }
        guard width <= limits.maxDimension, height <= limits.maxDimension else {
            throw AssetError.dimensionTooLarge
        }
        let (pixelCount, overflowed) = width.multipliedReportingOverflow(by: height)
        guard !overflowed, pixelCount <= limits.maxPixelCount else {
            throw AssetError.pixelCountTooLarge
        }
    }

    // MARK: - PNG

    /// PNG signature (`89 50 4E 47 0D 0A 1A 0A`) followed by an `IHDR` chunk
    /// whose first 8 bytes (after a 4-byte length and 4-byte "IHDR" tag) are
    /// the big-endian width and height.
    private static func parsePNGDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 33, data.prefix(8).elementsEqual(signature) else {
            throw AssetError.signatureMismatch
        }
        // Bytes 8-11: IHDR chunk length (must be 13). Bytes 12-15: "IHDR".
        let ihdrTag: [UInt8] = [0x49, 0x48, 0x44, 0x52]
        guard data[data.startIndex + 12 ..< data.startIndex + 16].elementsEqual(ihdrTag) else {
            throw AssetError.malformedImageData
        }
        let width = readUInt32BE(data, at: 16)
        let height = readUInt32BE(data, at: 20)
        guard let width, let height, width <= Int(Int32.max), height <= Int(Int32.max) else {
            throw AssetError.malformedImageData
        }
        return (Int(width), Int(height))
    }

    // MARK: - JPEG

    /// Walks JPEG markers from the SOI (`FF D8`) looking for a start-of-frame
    /// marker (`C0`–`CF`, excluding the DHT/JPG/DAC extension markers `C4`,
    /// `C8`, `CC`), whose payload begins with 1 precision byte then
    /// big-endian height then width.
    private static func parseJPEGDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        guard data.count >= 4, data[data.startIndex] == 0xFF,
              data[data.startIndex + 1] == 0xD8
        else {
            throw AssetError.signatureMismatch
        }
        var offset = data.startIndex + 2
        let end = data.endIndex

        while offset + 1 < end {
            guard data[offset] == 0xFF else {
                throw AssetError.malformedImageData
            }
            let markerOffset = try skipMarkerFillBytes(data, from: offset + 1, end: end)
            let marker = data[markerOffset]
            if marker == 0xD8 || marker == 0x01 || (0xD0 ... 0xD7).contains(marker) {
                offset = markerOffset + 1
                continue
            }
            if marker == 0xD9 {
                throw AssetError.malformedImageData
            }
            if let dimensions = try jpegSOFDimensions(
                data,
                marker: marker,
                markerOffset: markerOffset,
                end: end
            ) {
                return dimensions
            }
            offset = try jpegNextMarkerOffset(data, markerOffset: markerOffset, end: end)
        }
        throw AssetError.malformedImageData
    }

    /// Skips any `0xFF` fill bytes between a marker prefix and the marker
    /// byte itself, returning the index of the marker byte.
    private static func skipMarkerFillBytes(_ data: Data, from start: Int, end: Int) throws -> Int {
        var markerOffset = start
        while markerOffset < end, data[markerOffset] == 0xFF {
            markerOffset += 1
        }
        guard markerOffset < end else { throw AssetError.malformedImageData }
        return markerOffset
    }

    /// The start-of-frame markers (`C0`–`CF`, excluding the DHT/JPG/DAC
    /// extension markers `C4`, `C8`, `CC`) whose payload carries dimensions.
    private static let jpegSOFMarkers: Set<UInt8> = [
        0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
    ]

    /// Returns the parsed dimensions if `marker` is a start-of-frame marker,
    /// or `nil` if it is some other segment (its length is still validated).
    private static func jpegSOFDimensions(
        _ data: Data,
        marker: UInt8,
        markerOffset: Int,
        end: Int
    ) throws -> (width: Int, height: Int)? {
        guard jpegSOFMarkers.contains(marker) else { return nil }
        let payloadOffset = markerOffset + 3
        guard payloadOffset + 4 < end,
              let height = readUInt16BE(data, at: payloadOffset + 1),
              let width = readUInt16BE(data, at: payloadOffset + 3)
        else {
            throw AssetError.malformedImageData
        }
        return (Int(width), Int(height))
    }

    /// Reads the current segment's declared length and returns the offset
    /// of the next marker prefix, for segments that are not a start-of-frame.
    private static func jpegNextMarkerOffset(
        _ data: Data,
        markerOffset: Int,
        end: Int
    ) throws -> Int {
        let segmentLengthOffset = markerOffset + 1
        guard segmentLengthOffset + 1 < end,
              let length = readUInt16BE(data, at: segmentLengthOffset)
        else {
            throw AssetError.malformedImageData
        }
        guard length >= 2 else { throw AssetError.malformedImageData }
        return segmentLengthOffset + Int(length)
    }
}

extension AssetImageValidator {
    // MARK: - AVIF (ISO-BMFF)

    /// Walks top-level ISO-BMFF boxes looking for `ftyp` (validating the
    /// `avif`/`avis` brand) and then `meta` → `iprp` → `ipco` → the first
    /// `ispe` box, whose payload is a 4-byte version/flags field followed by
    /// big-endian width and height. Every box header is bounds-checked
    /// against the remaining buffer before being trusted, and box walking
    /// only ever moves forward, so a truncated or hostile box size cannot
    /// cause an out-of-bounds read or an infinite loop.
    private static func parseAVIFDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let boxes = try readBoxes(data, range: data.startIndex ..< data.endIndex, limit: 4096)
        try validateFtypBrand(data, boxes: boxes)
        let ispe = try locateISPEBox(data, topLevelBoxes: boxes)
        return try ispeDimensions(data, ispe: ispe)
    }

    /// Validates the top-level `ftyp` box's major/compatible brands include
    /// `avif` or `avis`.
    private static func validateFtypBrand(_ data: Data, boxes: [ISOBox]) throws {
        guard let ftyp = boxes.first(where: { $0.type == "ftyp" }) else {
            throw AssetError.signatureMismatch
        }
        guard ftyp.range.count >= 8 else { throw AssetError.malformedImageData }
        guard let majorBrand = String(
            bytes: data[ftyp.range.lowerBound ..< ftyp.range.lowerBound + 4],
            encoding: .utf8
        ) else {
            throw AssetError.malformedImageData
        }
        var compatibleBrands: Set<String> = [majorBrand]
        var brandOffset = ftyp.range.lowerBound + 8
        while brandOffset + 4 <= ftyp.range.upperBound {
            if let brand = String(bytes: data[brandOffset ..< brandOffset + 4], encoding: .utf8) {
                compatibleBrands.insert(brand)
            }
            brandOffset += 4
        }
        guard compatibleBrands.contains("avif") || compatibleBrands.contains("avis") else {
            throw AssetError.signatureMismatch
        }
    }

    /// Walks `meta` → `iprp` → `ipco` → the first `ispe` box among the
    /// top-level `boxes`.
    private static func locateISPEBox(_ data: Data, topLevelBoxes: [ISOBox]) throws -> ISOBox {
        guard let meta = topLevelBoxes.first(where: { $0.type == "meta" }) else {
            throw AssetError.malformedImageData
        }
        // A "meta" box has a 4-byte version/flags field before its children.
        let metaChildrenStart = meta.range.lowerBound + 4
        guard metaChildrenStart <= meta.range.upperBound else {
            throw AssetError.malformedImageData
        }
        var boxes = try readBoxes(
            data,
            range: metaChildrenStart ..< meta.range.upperBound,
            limit: 4096
        )
        guard let iprp = boxes.first(where: { $0.type == "iprp" }) else {
            throw AssetError.malformedImageData
        }
        boxes = try readBoxes(data, range: iprp.range, limit: 4096)
        guard let ipco = boxes.first(where: { $0.type == "ipco" }) else {
            throw AssetError.malformedImageData
        }
        boxes = try readBoxes(data, range: ipco.range, limit: 4096)
        guard let ispe = boxes.first(where: { $0.type == "ispe" }) else {
            throw AssetError.malformedImageData
        }
        return ispe
    }

    /// Parses an `ispe` box's payload (4-byte version/flags, then
    /// big-endian width and height), each bounded to fit `Int32`.
    private static func ispeDimensions(
        _ data: Data,
        ispe: ISOBox
    ) throws -> (width: Int, height: Int) {
        let payloadStart = ispe.range.lowerBound + 4
        guard let width = readUInt32BE(data, at: payloadStart),
              let height = readUInt32BE(data, at: payloadStart + 4),
              width <= Int(Int32.max), height <= Int(Int32.max)
        else {
            throw AssetError.malformedImageData
        }
        return (Int(width), Int(height))
    }

    private struct ISOBox {
        let type: String
        /// The byte range of this box's *payload* (after its header).
        let range: Range<Data.Index>
    }

    /// Parses a flat sequence of ISO-BMFF boxes within `range`, bounded by
    /// `limit` iterations as a defensive guard against a hostile file
    /// claiming an enormous number of zero-progress boxes.
    private static func readBoxes(
        _ data: Data,
        range: Range<Data.Index>,
        limit: Int
    ) throws -> [ISOBox] {
        var boxes: [ISOBox] = []
        var offset = range.lowerBound
        var iterations = 0
        while offset + 8 <= range.upperBound {
            iterations += 1
            guard iterations <= limit else { throw AssetError.malformedImageData }
            guard let size32 = readUInt32BE(data, at: offset)
            else { throw AssetError.malformedImageData }
            let headerSize: Int
            let boxSize: Int
            if size32 == 1 {
                // 64-bit extended size follows the 4-byte type.
                guard let size64 = readUInt64BE(data, at: offset + 8) else {
                    throw AssetError.malformedImageData
                }
                guard size64 <= UInt64(Int.max) else { throw AssetError.malformedImageData }
                headerSize = 16
                boxSize = Int(size64)
            } else if size32 == 0 {
                // Box extends to the end of the parent range.
                headerSize = 8
                boxSize = range.upperBound - offset
            } else {
                headerSize = 8
                boxSize = Int(size32)
            }
            guard boxSize >= headerSize, offset + boxSize <= range.upperBound else {
                throw AssetError.malformedImageData
            }
            guard let type = String(bytes: data[offset + 4 ..< offset + 8], encoding: .utf8) else {
                throw AssetError.malformedImageData
            }
            let payloadRange = (offset + headerSize) ..< (offset + boxSize)
            boxes.append(ISOBox(type: type, range: payloadRange))
            offset += boxSize
        }
        return boxes
    }

    // MARK: - Big-endian integer readers (bounds-checked, never trapping)

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.endIndex,
              offset >= data.startIndex else { return nil }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.endIndex,
              offset >= data.startIndex else { return nil }
        return (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.endIndex,
              offset >= data.startIndex else { return nil }
        var value: UInt64 = 0
        for index in 0 ..< 8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }
}
