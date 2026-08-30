import Foundation

extension AssetImageValidator {
    // MARK: - AVIF (ISO-BMFF) item-extent coverage

    /// A single parsed `iloc` item entry: which top-level byte range(s)
    /// (`extents`, already resolved to absolute file offsets) this item's
    /// coded data occupies.
    private struct ILOCItemEntry {
        let itemID: Int
        let constructionMethod: Int
        let extents: [Range<Int>]
    }

    /// Proves every byte inside every top-level `mdat` box is accounted
    /// for by some `iloc` item extent, and that no extent reaches outside
    /// its own `mdat` box.
    ///
    /// `parseAVIFDimensions` resolves the *primary* item's dimensions via
    /// `CGImageSourceCopyPropertiesAtIndex`, which reads exactly the coded
    /// data the `iloc`/`iinf`/`pitm` metadata *references* — it has no
    /// reason to notice, and does not report, additional bytes appended
    /// inside an `mdat` box beyond what any item's own extents point to.
    /// A size-zero (or oversized-explicit-size) `mdat` box "extends to the
    /// end of \[its parent range\]" by ISO-BMFF definition, so an attacker
    /// can append arbitrary trailing bytes after a real item's coded
    /// payload and still have them silently absorbed into that same
    /// `mdat` box, entirely outside any item's declared extent — bytes
    /// this validator would otherwise never inspect, in a namespace keyed
    /// only by the (identical) declared dimensions and format. This
    /// closes that gap by treating any such unreferenced byte, in any
    /// `mdat` box, as malformed: this pipeline's "no trailing/unreferenced
    /// data anywhere in a cached asset" contract (already enforced for
    /// JPEG's post-`EOI` bytes, PNG's exact zlib byte-count match, and this
    /// same file's own top-level box walk) applies just as strictly to
    /// bytes hidden *inside* a box's own declared span, not merely bytes
    /// past every top-level box.
    ///
    /// Not `private`: called from `parseAVIFDimensions` in
    /// `AssetImageValidator+AVIF.swift`.
    static func validateAVIFItemExtentCoverage(_ data: Data, boxes: [AVIFTopLevelBox]) throws {
        guard let meta = boxes.first(where: { $0.type == "meta" }) else {
            throw AssetError.malformedImageData
        }
        // `meta` is itself a `FullBox`: a 4-byte version+flags header
        // precedes its child box list.
        guard meta.range.count >= 4 else { throw AssetError.malformedImageData }
        let metaChildren = try readAVIFTopLevelBoxes(
            data,
            range: (meta.range.lowerBound + 4) ..< meta.range.upperBound,
            limit: 256
        )
        guard let iloc = metaChildren.first(where: { $0.type == "iloc" }) else {
            // Every real AVIF item's coded data is referenced through
            // `iloc`; a `meta` box with no `iloc` at all leaves nothing
            // for this coverage proof to anchor to, so any `mdat` bytes
            // are unreferenced by definition -- fail closed rather than
            // silently trust ImageIO's own (narrower, per-item) view.
            throw AssetError.malformedImageData
        }

        let items = try parseILOC(data, box: iloc)
        let mdatBoxes = boxes.filter { $0.type == "mdat" }
        guard !mdatBoxes.isEmpty else {
            // No coded media at all: `iloc` referencing zero mdat bytes is
            // consistent only if every item has zero extents, which is
            // never true for a real coded image -- reject either way.
            throw AssetError.malformedImageData
        }

        var extentsByMdat: [Int: [Range<Int>]] = [:]
        for item in items {
            // Construction method 1 (`idat`-relative) and 2
            // (item-reference-relative) address coded data outside any
            // `mdat` box entirely; this coverage proof only reasons about
            // `mdat` contents, so an item using either is rejected rather
            // than silently excluded from the coverage accounting (which
            // would let its own `idat` bytes go completely unverified).
            guard item.constructionMethod == 0 else {
                throw AssetError.malformedImageData
            }
            for extent in item.extents {
                guard let mdatIndex = mdatBoxes.firstIndex(where: { $0.range.contains(extent) })
                else {
                    // An extent that lands outside every declared `mdat`
                    // box's payload (or straddles more than one) can never
                    // be genuinely decodable input -- ImageIO would also
                    // reject it, but this proves it explicitly rather than
                    // relying on that as the only line of defense.
                    throw AssetError.malformedImageData
                }
                extentsByMdat[mdatIndex, default: []].append(extent)
            }
        }

        for (index, mdat) in mdatBoxes.enumerated() {
            let extents = extentsByMdat[index] ?? []
            try validateExactCoverage(of: mdat.range, by: extents)
        }
    }

    /// Proves a sorted, deduplicated set of `extents` exactly tiles
    /// `range` with no gaps, no overlaps, and nothing outside `range` --
    /// i.e. every byte of `range` belongs to exactly one extent.
    private static func validateExactCoverage(
        of range: Range<Int>,
        by extents: [Range<Int>]
    ) throws {
        guard !extents.isEmpty else { throw AssetError.malformedImageData }
        let sorted = extents.sorted { $0.lowerBound < $1.lowerBound }
        var cursor = range.lowerBound
        for extent in sorted {
            guard !extent.isEmpty else { throw AssetError.malformedImageData }
            guard extent.lowerBound == cursor, extent.upperBound <= range.upperBound else {
                // A gap, an overlap, or an extent starting before the
                // previous one ended are all rejected identically: any of
                // them proves the declared extents do not exactly
                // partition this box's bytes.
                throw AssetError.malformedImageData
            }
            cursor = extent.upperBound
        }
        guard cursor == range.upperBound else {
            // Bytes remain after the last extent ends: unreferenced
            // trailing payload, exactly the class of defect this check
            // exists to close.
            throw AssetError.malformedImageData
        }
    }

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

        offset += 2 // data_reference_index: unused (this proof only supports index 0/this file)
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
    private static func parseILOC(_ data: Data, box: AVIFTopLevelBox) throws -> [ILOCItemEntry] {
        let range = box.range
        guard range.count >= 4 else { throw AssetError.malformedImageData }
        let version = Int(data[range.lowerBound])
        var offset = range.lowerBound + 4 // past version(1) + flags(3)

        let fieldSizes = try parseILOCFieldSizes(data, at: &offset, range: range, version: version)
        let itemCount = try readVersionSizedField(data, at: &offset, version: version)

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
}
