import Foundation

/// Full PNG chunk-structure validation, beyond ``AssetImageValidator``'s
/// pure `IHDR`-only dimension parse.
///
/// A truncated PNG (for example, cut off partway through its `IDAT`
/// stream) can still declare a perfectly valid `IHDR` and even still
/// successfully produce *a* `CGImage` from ImageIO's lazy,
/// best-effort decoder — ImageIO does not reliably surface an "incomplete
/// source" status for a non-incremental `CGImageSourceCreateWithData` call
/// in practice, so a merely-decodes check alone is not a trustworthy
/// completeness gate. This walks every chunk explicitly, requiring: the
/// first chunk is `IHDR`; at least one `IDAT` chunk is present; `PLTE`
/// and `tRNS` (if present) each obey the PNG specification's own
/// color-type-dependent presence, ordering, and payload-shape rules (see
/// ``validatePLTEChunk(dataRange:colorInfo:paletteEntryCount:)``/
/// ``validateTRNSChunk(dataRange:colorInfo:paletteEntryCount:)``); the
/// file ends with a critical `IEND` chunk and not a single byte of
/// trailing data after it; and every chunk's declared CRC-32 (over its
/// own type and data, exactly as the PNG specification defines it)
/// matches what its bytes actually checksum to — the same mechanism that
/// would catch a `IDAT` truncated or corrupted mid-stream, since removing
/// or altering even one byte changes that chunk's checksum.
extension AssetImageValidator {
    /// Validates every chunk's container-level structure and returns the
    /// exact concatenated bytes of every `IDAT` chunk's own data (in file
    /// order, excluding each chunk's length/type/CRC framing) -- the
    /// single RFC 1950 zlib datastream the PNG specification requires
    /// their concatenation to form, which
    /// ``validateExactPNGInflation(idatPayload:rowByteCount:rowCount:)`` then
    /// decompresses and checks for an exact byte-count match.
    ///
    /// `colorInfo` — already parsed from this same file's `IHDR` by the
    /// caller — drives `PLTE`/`tRNS`'s own color-type-dependent
    /// presence/shape rules below.
    @discardableResult
    static func validatePNGStructure(_ data: Data, colorInfo: PNGColorInfo) throws -> Data {
        var offset = data.startIndex + 8 // past the 8-byte signature
        var sawIDAT = false
        // PNG requires every `IDAT` chunk to appear consecutively, with no
        // other chunk type interposed between them — a file with `IDAT`
        // chunks split apart by an intervening (even CRC-valid) ancillary
        // chunk is not a spec-conforming PNG and must not be trusted, even
        // though each individual chunk's own CRC still checks out.
        var idatRunEnded = false
        var isFirstChunk = true
        var idatPayload = Data()
        var sawTRNS = false
        // `nil` doubles as "PLTE not yet seen" (`handlePLTEChunk` either
        // throws or returns a non-`nil` entry count, so this alone always
        // tracks both facts at once, without a separate `sawPLTE` bool
        // that could otherwise drift out of sync with it).
        var paletteEntryCount: Int?

        while true {
            let chunk = try validatePNGChunk(data, at: offset)

            if isFirstChunk {
                guard chunk.type == "IHDR" else { throw AssetError.malformedImageData }
                isFirstChunk = false
            }
            switch chunk.type {
            case "IDAT":
                guard !idatRunEnded else { throw AssetError.malformedImageData }
                sawIDAT = true
                idatPayload.append(data[chunk.dataRange])
            case "PLTE":
                paletteEntryCount = try handlePLTEChunk(
                    chunk, colorInfo: colorInfo, sawIDAT: sawIDAT,
                    sawPLTE: paletteEntryCount != nil
                )
            case "tRNS":
                try handleTRNSChunk(
                    chunk, colorInfo: colorInfo, sawIDAT: sawIDAT, sawTRNS: sawTRNS,
                    paletteEntryCount: paletteEntryCount
                )
                sawTRNS = true
            case "IEND":
                try handleIENDChunk(
                    chunk,
                    data: data,
                    colorInfo: colorInfo,
                    sawIDAT: sawIDAT,
                    sawPLTE: paletteEntryCount != nil
                )
                return idatPayload
            default:
                break
            }
            if chunk.type != "IDAT", sawIDAT {
                idatRunEnded = true
            }
            offset = chunk.chunkEnd
        }
    }

    /// `PLTE`-specific dispatch from ``validatePNGStructure(_:colorInfo:)``'s
    /// main chunk-walk loop: enforces "before `IDAT`" ordering and
    /// duplicate rejection (both position-dependent on the walk's own
    /// running state, not `validatePLTEChunk`'s own payload-shape checks),
    /// then delegates the payload itself.
    private static func handlePLTEChunk(
        _ chunk: PNGChunk,
        colorInfo: PNGColorInfo,
        sawIDAT: Bool,
        sawPLTE: Bool
    ) throws -> Int {
        // Both `PLTE` and `tRNS` are only ever valid before the `IDAT`
        // run begins -- one appearing during or after it (even between
        // two separate, otherwise-consecutive `IDAT` chunks, which the
        // caller's own run-tracking already rejects outright) is not
        // spec-conforming.
        guard !sawIDAT else { throw AssetError.malformedImageData }
        guard !sawPLTE else { throw AssetError.malformedImageData }
        return try validatePLTEChunk(dataRange: chunk.dataRange, colorInfo: colorInfo)
    }

    /// `tRNS`-specific dispatch from ``validatePNGStructure(_:colorInfo:)``'s
    /// main chunk-walk loop; see ``handlePLTEChunk(_:colorInfo:sawIDAT:sawPLTE:)``
    /// for why ordering/duplicate rejection lives here rather than in
    /// `validateTRNSChunk` itself. `paletteEntryCount != nil` alone (see
    /// ``validatePNGStructure(_:colorInfo:)``'s own local variable
    /// comment) doubles as this call's own "already saw PLTE" signal, so
    /// no separate `sawPLTE` parameter is needed to stay within this
    /// package's `function_parameter_count` convention.
    private static func handleTRNSChunk(
        _ chunk: PNGChunk,
        colorInfo: PNGColorInfo,
        sawIDAT: Bool,
        sawTRNS: Bool,
        paletteEntryCount: Int?
    ) throws {
        guard !sawIDAT else { throw AssetError.malformedImageData }
        guard !sawTRNS else { throw AssetError.malformedImageData }
        try validateTRNSChunk(
            dataRange: chunk.dataRange,
            colorInfo: colorInfo,
            paletteEntryCount: paletteEntryCount,
            sawPLTE: paletteEntryCount != nil
        )
    }

    /// `IEND`-specific dispatch from ``validatePNGStructure(_:colorInfo:)``'s
    /// main chunk-walk loop: strict no-trailing-bytes/zero-payload/
    /// `IDAT`-present/indexed-`PLTE`-required terminal checks.
    private static func handleIENDChunk(
        _ chunk: PNGChunk,
        data: Data,
        colorInfo: PNGColorInfo,
        sawIDAT: Bool,
        sawPLTE: Bool
    ) throws {
        // Strict no-trailing-bytes policy: `IEND` must be the exact final
        // chunk in the buffer, not merely present somewhere before other,
        // ignored trailing data.
        guard chunk.chunkEnd == data.endIndex else { throw AssetError.malformedImageData }
        guard sawIDAT else { throw AssetError.malformedImageData }
        // The PNG specification mandates a zero-byte `IEND` payload. A
        // structurally-invalid file that gives `IEND` a nonempty payload
        // (while still keeping its CRC internally consistent with that
        // payload) can still report a CRC match and reach EOF here, yet
        // ImageIO may still lazily decode *something* from the
        // surrounding stream — never treat that leniency as validation.
        guard chunk.dataRange.isEmpty else { throw AssetError.malformedImageData }
        // Indexed-color images have no other source of per-pixel color;
        // a missing `PLTE` for color type 3 means every pixel index in
        // the (otherwise structurally valid) `IDAT` stream refers to
        // nothing.
        guard colorInfo.colorType != 3 || sawPLTE else {
            throw AssetError.malformedImageData
        }
    }

    /// Validates a `PLTE` chunk's payload against `colorInfo`'s color
    /// type and bit depth, returning its entry count for a later `tRNS`
    /// chunk (if any) to cross-check against.
    ///
    /// - Grayscale (0) and grayscale+alpha (4) images carry no per-pixel
    ///   color channel `PLTE` could ever apply to, so the specification
    ///   forbids it outright for both.
    /// - Every entry is exactly 3 bytes (one R/G/B triple); a payload
    ///   whose length is not a multiple of 3 is malformed.
    /// - Cardinality must be at least 1 and at most `min(256, 2^bitDepth)`:
    ///   256 is the specification's own hard ceiling (a `PLTE` entry index
    ///   is always a single byte, regardless of color type), and
    ///   `2^bitDepth` additionally bounds indexed-color (3) images, whose
    ///   pixel data can only ever encode indices up to that many distinct
    ///   values -- for truecolor (2) and truecolor+alpha (6), `bitDepth`
    ///   is always 8 or 16 (enforced by ``pngAllowedBitDepths(for:)``),
    ///   so `2^bitDepth` is always at least 256 there and this bound
    ///   reduces to the flat 256 ceiling for both.
    private static func validatePLTEChunk(
        dataRange: Range<Int>,
        colorInfo: PNGColorInfo
    ) throws -> Int {
        guard colorInfo.colorType != 0, colorInfo.colorType != 4 else {
            throw AssetError.malformedImageData
        }
        guard dataRange.count % 3 == 0, !dataRange.isEmpty else {
            throw AssetError.malformedImageData
        }
        let entryCount = dataRange.count / 3
        // `bitDepth` is raw, not-yet-range-checked `IHDR` input at this
        // point (``pngAllowedBitDepths(for:)``'s own guard against this
        // value runs later, from ``pngRowByteCount(width:colorInfo:)``):
        // an out-of-spec value greater than 16 must never reach the bit
        // shift below, which would otherwise trap for any shift amount
        // at or beyond `Int`'s own bit width.
        guard colorInfo.bitDepth <= 16 else { throw AssetError.malformedImageData }
        let maxEntries = min(256, 1 << Int(colorInfo.bitDepth))
        guard entryCount <= maxEntries else {
            throw AssetError.malformedImageData
        }
        return entryCount
    }

    /// Validates a `tRNS` chunk's payload against `colorInfo`'s color
    /// type (and, for indexed color, the preceding `PLTE`'s own entry
    /// count).
    ///
    /// - Grayscale+alpha (4) and truecolor+alpha (6) images already carry
    ///   a full per-pixel alpha channel in `IDAT`, so the specification
    ///   forbids `tRNS` outright for both.
    /// - Indexed-color (3) images require `PLTE` to already have
    ///   appeared (there is otherwise nothing for a `tRNS` entry index to
    ///   apply to), and `tRNS`'s own entry count -- one alpha byte per
    ///   entry, assigned in the same order as `PLTE`'s own entries --
    ///   must not exceed `PLTE`'s entry count (a shorter `tRNS` is valid;
    ///   any palette entry it does not cover defaults to fully opaque).
    /// - Grayscale (0) `tRNS` is always exactly one 16-bit gray value (2
    ///   bytes); truecolor (2) is always one 16-bit R/G/B triple (6
    ///   bytes) -- both fixed-length regardless of `bitDepth`, naming the
    ///   single color value to treat as fully transparent.
    private static func validateTRNSChunk(
        dataRange: Range<Int>,
        colorInfo: PNGColorInfo,
        paletteEntryCount: Int?,
        sawPLTE: Bool
    ) throws {
        switch colorInfo.colorType {
        case 0:
            guard dataRange.count == 2 else { throw AssetError.malformedImageData }
        case 2:
            guard dataRange.count == 6 else { throw AssetError.malformedImageData }
        case 3:
            guard sawPLTE, let paletteEntryCount else { throw AssetError.malformedImageData }
            guard dataRange.count <= paletteEntryCount else {
                throw AssetError.malformedImageData
            }
        default:
            // Color types 4 and 6 already carry a full alpha channel.
            throw AssetError.malformedImageData
        }
    }

    /// A single validated PNG chunk: the offset just past it, its
    /// 4-character type, and the exact range of its own data bytes
    /// (excluding the length/type/CRC framing). A dedicated struct rather
    /// than a tuple purely to keep this package's tuple-arity convention.
    private struct PNGChunk {
        let chunkEnd: Int
        let type: String
        let dataRange: Range<Int>
    }

    /// Validates a single PNG chunk starting at `offset` — its declared
    /// length, its type field is valid ASCII, and its CRC-32 matches —
    /// returning the offset just past it, its 4-character type, and the
    /// exact range of its own data bytes (excluding the length/type/CRC
    /// framing).
    /// Factored out of ``validatePNGStructure(_:)`` purely to keep that
    /// function's own cyclomatic complexity within this package's
    /// convention.
    private static func validatePNGChunk(
        _ data: Data,
        at offset: Int
    ) throws -> PNGChunk {
        guard offset < data.endIndex else {
            // Ran off the end of the buffer without ever reaching a
            // terminal `IEND` chunk: truncated.
            throw AssetError.malformedImageData
        }
        guard let length = readUInt32BE(data, at: offset) else {
            throw AssetError.malformedImageData
        }
        let typeStart = offset + 4
        guard typeStart + 4 <= data.endIndex else {
            throw AssetError.malformedImageData
        }
        guard let type = String(bytes: data[typeStart ..< typeStart + 4], encoding: .ascii) else {
            throw AssetError.malformedImageData
        }

        let dataStart = typeStart + 4
        let (dataEnd, overflowed) = dataStart.addingReportingOverflow(Int(length))
        guard !overflowed, dataEnd <= data.endIndex else {
            throw AssetError.malformedImageData
        }
        let crcStart = dataEnd
        guard let storedCRC = readUInt32BE(data, at: crcStart) else {
            throw AssetError.malformedImageData
        }
        let computedCRC = CRC32.checksum(data[typeStart ..< dataEnd])
        guard computedCRC == storedCRC else {
            throw AssetError.malformedImageData
        }
        return PNGChunk(chunkEnd: crcStart + 4, type: type, dataRange: dataStart ..< dataEnd)
    }
}
