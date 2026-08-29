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
/// PNG and JPEG dimension parsing is pure and allocation-light and depends
/// on no platform image decoder, so it runs identically across every
/// supported platform and is exercised by plain byte-array fixtures in
/// tests without needing real image decode support. AVIF's primary-item
/// dimensions are instead resolved via a bounded ImageIO metadata read (see
/// `AssetImageValidator+AVIF.swift`): AVIF's primary-item association
/// (`pitm`/`ipma`/`ipco`/`ispe`) is a multi-box, cross-referencing
/// structure a platform image framework is far better positioned to
/// resolve correctly than a hand-rolled box walk, which risks silently
/// reporting a non-primary item's dimensions.
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
        guard data.count >= 8, data.prefix(8).elementsEqual(signature) else {
            throw AssetError.signatureMismatch
        }
        // The signature itself matched, so any further shortfall is a
        // truncated/malformed PNG, not a wrong-format file.
        guard data.count >= 33 else {
            throw AssetError.malformedImageData
        }
        // Bytes 8-11: IHDR chunk length (must be 13). Bytes 12-15: "IHDR".
        guard readUInt32BE(data, at: 8) == 13 else {
            throw AssetError.malformedImageData
        }
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
        // Only the 2-byte SOI marker itself determines whether this is
        // JPEG data at all; a buffer that is shorter than that can never
        // have matched. A buffer that *does* start with the SOI marker but
        // is truncated immediately afterward is JPEG data that is too
        // short to parse — `malformedImageData`, the same classification
        // the PNG/AVIF branches use for "signature matches but data is too
        // short" — not `signatureMismatch`, which the while loop below
        // (and its trailing `throw` once no more markers remain) already
        // produces once `offset` cannot advance past `end`.
        guard data.count >= 2, data[data.startIndex] == 0xFF,
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
    /// or `nil` immediately if it is some other segment — this function does
    /// not itself validate a non-SOF segment's declared length; that
    /// happens later, in `jpegNextMarkerOffset`, when the scan advances past
    /// it.
    ///
    /// For a start-of-frame marker, validates the segment's own declared
    /// length (not just that reading stays within the whole buffer): a
    /// segment whose declared length is too short to actually contain the
    /// precision/height/width fields is rejected rather than silently
    /// reading past its boundary into whatever bytes happen to follow
    /// (which could belong to an entirely different segment) and returning
    /// bogus-but-plausible dimensions.
    private static func jpegSOFDimensions(
        _ data: Data,
        marker: UInt8,
        markerOffset: Int,
        end: Int
    ) throws -> (width: Int, height: Int)? {
        guard jpegSOFMarkers.contains(marker) else { return nil }
        let segmentLengthOffset = markerOffset + 1
        guard segmentLengthOffset + 1 < end,
              let segmentLength = readUInt16BE(data, at: segmentLengthOffset)
        else {
            throw AssetError.malformedImageData
        }
        // The segment length field includes its own 2 bytes, so a valid
        // SOF payload needs: 1-byte precision, 2-byte height, 2-byte
        // width, 1-byte component count, and at least one 3-byte
        // component descriptor (Ci/HiVi/Tqi) — 11 bytes total, including
        // the length field itself. Anything shorter is missing required
        // fields and must fail closed rather than be accepted (and
        // potentially cached) on the strength of a plausible-looking
        // width/height alone. The whole declared segment must also fit
        // within `data`.
        guard segmentLength >= 11, segmentLengthOffset + Int(segmentLength) <= end else {
            throw AssetError.malformedImageData
        }
        let payloadOffset = markerOffset + 3
        guard let height = readUInt16BE(data, at: payloadOffset + 1),
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

    // MARK: - Big-endian integer readers (bounds-checked, never trapping)

    /// Not `private`: also used by the AVIF (ISO-BMFF) parsing in
    /// `AssetImageValidator+AVIF.swift`, a separate file purely to stay
    /// under SwiftLint's `file_length`.
    static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.endIndex,
              offset >= data.startIndex else { return nil }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.endIndex,
              offset >= data.startIndex else { return nil }
        return (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.endIndex,
              offset >= data.startIndex else { return nil }
        var value: UInt64 = 0
        for index in 0 ..< 8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }
}
