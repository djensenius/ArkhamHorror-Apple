import Foundation

extension AssetImageValidator {
    // MARK: - AVIF (ISO-BMFF) item-extent coverage

    /// A single parsed `iloc` item entry: which top-level byte range(s)
    /// (`extents`, already resolved to absolute file offsets) this item's
    /// coded data occupies.
    struct ILOCItemEntry {
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
                guard let mdatIndex = mdatBoxes.firstIndex(where: {
                    // Explicit "does `$0.range` fully contain `extent`"
                    // bound comparison, rather than relying on
                    // `Range.contains(_ other: Range<Bound>)` (a real,
                    // documented overload in the Swift standard library,
                    // not `Sequence.contains(_:Element)` — but easy for a
                    // reader to mistake for the wrong one, and its
                    // "any empty range is always contained regardless of
                    // position" behavior is not the semantics wanted
                    // here): an extent is only ever genuinely inside an
                    // `mdat` box if it is non-empty and its bounds fall
                    // entirely within that box's own range.
                    !extent.isEmpty
                        && extent.lowerBound >= $0.range.lowerBound
                        && extent.upperBound <= $0.range.upperBound
                })
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
}
