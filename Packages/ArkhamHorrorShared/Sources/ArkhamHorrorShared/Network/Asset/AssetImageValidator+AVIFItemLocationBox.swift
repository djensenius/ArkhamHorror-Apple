import Foundation

/// `iloc` box (item-location table) field-size/extent parsers used by
/// `AssetImageValidator/validateAVIFItemExtentCoverage(_:boxes:)`. Split
/// out of `AssetImageValidator+AVIFItemExtents.swift` purely to keep
/// that file within this package's `file_length` convention.
extension AssetImageValidator {
    /// The `offset_size`/`length_size`/`base_offset_size`/`index_size`
    /// nibble fields shared by every item entry in one `iloc` box.
    private struct ILOCFieldSizes {
        let offsetSize: Int
        let lengthSize: Int
        let baseOffsetSize: Int
        let indexSize: Int
        let version: Int
    }

    /// Reads one `offset_size`/`length_size`/`base_offset_size`-style
    /// field, whose byte width is only ever 0, 4, or 8 for any real
    /// encoder -- any other nibble value fails closed rather than
    /// attempting a best-effort parse of a form no test fixture can prove
    /// correct. Split out of ``parseILOC(_:box:)`` purely to keep that
    /// function's own body/complexity within this project's configured
    /// `SwiftLint` limits.
    private static func readSizedField(
        _ data: Data,
        at offset: inout Int,
        sizeInBytes: Int
    ) throws -> UInt64 {
        switch sizeInBytes {
        case 0:
            return 0
        case 4:
            guard let value = readUInt32BE(data, at: offset) else {
                throw AssetError.malformedImageData
            }
            offset += 4
            return UInt64(value)
        case 8:
            guard let value = readUInt64BE(data, at: offset) else {
                throw AssetError.malformedImageData
            }
            offset += 8
            return value
        default:
            throw AssetError.malformedImageData
        }
    }

    /// Reads a version-dependent `iloc` field: a 16-bit value for
    /// version < 2, a 32-bit value otherwise (`item_count`/`item_ID`
    /// share this exact encoding per ISO/IEC 14496-12 §8.11.3).
    private static func readVersionSizedField(
        _ data: Data,
        at offset: inout Int,
        version: Int
    ) throws -> Int {
        if version < 2 {
            guard let value = readUInt16BE(data, at: offset) else {
                throw AssetError.malformedImageData
            }
            offset += 2
            return Int(value)
        } else {
            guard let value = readUInt32BE(data, at: offset) else {
                throw AssetError.malformedImageData
            }
            offset += 4
            return Int(value)
        }
    }

    /// Parses the `offset_size`/`length_size`/`base_offset_size`/
    /// `index_size` nibble fields at the start of one `iloc` item-entry
    /// block, validating that every size is 0, 4, or 8.
    private static func parseILOCFieldSizes(
        _ data: Data,
        at offset: inout Int,
        range: Range<Int>,
        version: Int
    ) throws -> ILOCFieldSizes {
        guard offset + 2 <= range.upperBound else { throw AssetError.malformedImageData }
        let sizeNibbles = data[offset]
        let offsetSize = Int(sizeNibbles >> 4)
        let lengthSize = Int(sizeNibbles & 0x0F)
        let baseOffsetNibbles = data[offset + 1]
        let baseOffsetSize = Int(baseOffsetNibbles >> 4)
        let indexSize = Int(baseOffsetNibbles & 0x0F)
        offset += 2
        let validSizes = [offsetSize, lengthSize, baseOffsetSize]
        for size in validSizes where size != 0 && size != 4 && size != 8 {
            throw AssetError.malformedImageData
        }
        return ILOCFieldSizes(
            offsetSize: offsetSize,
            lengthSize: lengthSize,
            baseOffsetSize: baseOffsetSize,
            indexSize: indexSize,
            version: version
        )
    }

    /// Parses one item's `extent_count` extents, resolving each to an
    /// absolute file-offset `Range<Int>` relative to `baseOffset`. Split
    /// out of ``parseILOC(_:box:)`` purely to keep that function's own
    /// body/complexity within this project's configured `SwiftLint`
    /// limits.
    private static func parseILOCExtents(
        _ data: Data,
        offset: inout Int,
        extentCount: Int,
        fieldSizes: ILOCFieldSizes,
        baseOffset: UInt64
    ) throws -> [Range<Int>] {
        var extents: [Range<Int>] = []
        extents.reserveCapacity(extentCount)
        for _ in 0 ..< extentCount {
            if fieldSizes.version == 1 || fieldSizes.version == 2, fieldSizes.indexSize != 0 {
                // item_reference_index -- only meaningful for
                // construction method 2, which is rejected outright
                // wherever `constructionMethod` is consulted; skip past
                // its bytes here purely to keep the remaining
                // offset/length fields correctly aligned.
                _ = try readSizedField(data, at: &offset, sizeInBytes: fieldSizes.indexSize)
            }
            let extentOffset = try readSizedField(
                data,
                at: &offset,
                sizeInBytes: fieldSizes.offsetSize
            )
            let extentLength = try readSizedField(
                data,
                at: &offset,
                sizeInBytes: fieldSizes.lengthSize
            )
            guard extentLength > 0 else { throw AssetError.malformedImageData }
            let (start, startOverflowed) = baseOffset.addingReportingOverflow(extentOffset)
            guard !startOverflowed, start <= UInt64(Int.max) else {
                throw AssetError.malformedImageData
            }
            let (end, endOverflowed) = start.addingReportingOverflow(extentLength)
            guard !endOverflowed, end <= UInt64(Int.max) else {
                throw AssetError.malformedImageData
            }
            extents.append(Int(start) ..< Int(end))
        }
        return extents
    }

    /// Parses one `iloc` item entry (item ID, construction method, base
    /// offset, and every resolved extent). Split out of
    /// ``parseILOC(_:box:)`` purely to keep that function's own
    /// body/complexity within this project's configured `SwiftLint`
    /// limits.
    private static func parseILOCItem(
        _ data: Data,
        offset: inout Int,
        range: Range<Int>,
        version: Int,
        fieldSizes: ILOCFieldSizes
    ) throws -> ILOCItemEntry {
        let itemID = try readVersionSizedField(data, at: &offset, version: version)

        var constructionMethod = 0
        if version == 1 || version == 2 {
            guard let value = readUInt16BE(data, at: offset) else {
                throw AssetError.malformedImageData
            }
            offset += 2
            constructionMethod = Int(value & 0x0F)
        }

        // `data_reference_index`: this proof only supports items whose
        // coded bytes live in *this* file (index 0, "self-contained" per
        // ISO/IEC 14496-12 §8.7.2/§8.11.3); any nonzero value references
        // an external `dref` entry this parser never resolves, so
        // trusting `baseOffset`/extents against *this* file's own
        // `mdat` boxes would silently validate coverage of bytes that
        // are not actually what the item's coded data refers to at all.
        // Reject every nonzero value under this asset contract rather
        // than attempt to parse `dref` just to prove it is unsupported.
        guard let dataReferenceIndex = readUInt16BE(data, at: offset) else {
            throw AssetError.malformedImageData
        }
        offset += 2
        guard dataReferenceIndex == 0 else { throw AssetError.malformedImageData }
        let baseOffset = try readSizedField(
            data,
            at: &offset,
            sizeInBytes: fieldSizes.baseOffsetSize
        )
        guard baseOffset <= UInt64(Int.max) else { throw AssetError.malformedImageData }

        guard offset + 2 <= range.upperBound else { throw AssetError.malformedImageData }
        guard let extentCountValue = readUInt16BE(data, at: offset) else {
            throw AssetError.malformedImageData
        }
        offset += 2

        let extents = try parseILOCExtents(
            data,
            offset: &offset,
            extentCount: Int(extentCountValue),
            fieldSizes: fieldSizes,
            baseOffset: baseOffset
        )
        guard offset <= range.upperBound else { throw AssetError.malformedImageData }
        return ILOCItemEntry(
            itemID: itemID,
            constructionMethod: constructionMethod,
            extents: extents
        )
    }

    /// Parses an `iloc` box's item entries (ISO/IEC 14496-12 §8.11.3),
    /// resolving every extent to an absolute file-offset `Range<Int>`.
    /// Only `offset_size`/`length_size`/`base_offset_size` values of 0, 4,
    /// or 8 (the only values any real encoder emits) are accepted; any
    /// other nibble value, and any `index_size` field's referenced-item
    /// construction path (relevant only to construction method 2, which
    /// this file rejects outright), fails closed rather than attempting a
    /// best-effort parse of a form no test fixture can prove correct.
    static func parseILOC(_ data: Data, box: AVIFTopLevelBox) throws -> [ILOCItemEntry] {
        let range = box.range
        guard range.count >= 4 else { throw AssetError.malformedImageData }
        let version = Int(data[range.lowerBound])
        var offset = range.lowerBound + 4 // past version(1) + flags(3)

        let fieldSizes = try parseILOCFieldSizes(data, at: &offset, range: range, version: version)
        let itemCount = try readVersionSizedField(data, at: &offset, version: version)

        // `itemCount` is attacker-controlled (up to `UInt32.max` under
        // version >= 2) and read *before* any proof that the box
        // actually contains that many entries -- `reserveCapacity`
        // trusting it directly would let a few-byte malformed box demand
        // a many-gigabyte allocation purely from a single 32-bit field,
        // independent of this asset's already-enforced encoded-byte cap.
        // Every real item entry occupies at least this many bytes (item
        // ID + optional construction-method word + `data_reference_index`
        // + base offset + the `extent_count` field itself, even before
        // any extent), so `itemCount` can never legitimately exceed the
        // remaining box bytes divided by that minimum -- reject outright
        // rather than merely truncating the allocation, since a box
        // genuinely this malformed cannot self-consistently claim more
        // items than it has room to describe.
        let itemIDFieldBytes = version < 2 ? 2 : 4
        let constructionMethodFieldBytes = (version == 1 || version == 2) ? 2 : 0
        let minimumBytesPerItem = itemIDFieldBytes
            + constructionMethodFieldBytes
            + 2 // data_reference_index
            + fieldSizes.baseOffsetSize
            + 2 // extent_count
        let remainingBytes = range.upperBound - offset
        guard
            minimumBytesPerItem > 0,
            remainingBytes >= 0,
            itemCount <= remainingBytes / minimumBytesPerItem,
            itemCount <= Self.maxILOCItemCount
        else {
            throw AssetError.malformedImageData
        }

        var entries: [ILOCItemEntry] = []
        entries.reserveCapacity(itemCount)
        for _ in 0 ..< itemCount {
            try entries.append(
                parseILOCItem(
                    data,
                    offset: &offset,
                    range: range,
                    version: version,
                    fieldSizes: fieldSizes
                )
            )
        }
        guard offset <= range.upperBound else { throw AssetError.malformedImageData }
        return entries
    }

    /// An explicit, generous-but-bounded absolute cap on `iloc` item
    /// count, independent of the box's own declared size: no real AVIF
    /// encoder emits more than a handful of items (this validator's own
    /// exactly-one-item contract enforces that far more narrowly
    /// elsewhere), so this exists purely as defense-in-depth alongside
    /// the remaining-bytes-based bound above.
    private static let maxILOCItemCount = 4096
}
