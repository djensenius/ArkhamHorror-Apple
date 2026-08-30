import CoreGraphics
import Foundation
import ImageIO

extension AssetImageValidator {
    // MARK: - AVIF (ISO-BMFF)

    /// Validates the top-level `ftyp` box's brand as a fast, pure,
    /// allocation-light pre-filter (see ``validateFtypBrand(_:boxes:)``),
    /// then resolves the *primary* item's pixel dimensions via ImageIO
    /// rather than a hand-rolled `meta`/`iprp`/`ipco`/`ispe` walk.
    ///
    /// AVIF's primary-item association (`pitm` + `ipma` linking specific
    /// property indices, including which `ispe` box, to the primary item)
    /// is exactly the kind of multi-box, cross-referencing structure a
    /// platform image framework is best positioned to resolve correctly —
    /// a flat "first `ispe` box in document order" walk (this file's
    /// previous approach) can silently report a *non-primary* item's
    /// dimensions for a multi-item AVIF file, passing validation with the
    /// wrong size entirely. `CGImageSourceCopyPropertiesAtIndex` reads only
    /// this file format's own metadata — not a full pixel decode, so no
    /// large allocation happens here — and, on every platform this package
    /// deploys to (see `Package.swift`), correctly resolves the primary
    /// item the same way a full AVIF decode itself would.
    ///
    /// Not `private`: called from the main format dispatch in
    /// `AssetImageValidator.swift`.
    static func parseAVIFDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let boxes = try readAVIFTopLevelBoxes(
            data,
            range: data.startIndex ..< data.endIndex,
            limit: 4096
        )
        try validateFtypBrand(data, boxes: boxes)
        // Proven *before* resolving dimensions: ImageIO only ever looks at
        // the bytes each item's own `iloc` extents reference, so it has no
        // way to notice (and would not reject) extra bytes an attacker
        // appends inside an `mdat` box's own declared span, outside every
        // item's referenced extent. See
        // ``validateAVIFItemExtentCoverage(_:boxes:)`` for the full
        // rationale.
        try validateAVIFItemExtentCoverage(data, boxes: boxes)
        return try avifPrimaryItemDimensions(data)
    }

    /// Resolves the primary image item's pixel dimensions via ImageIO,
    /// without ever fully decoding pixels: `CGImageSourceCopyPropertiesAtIndex`
    /// reads only container/property metadata for the item at `index`,
    /// bounded work regardless of how large the (not-yet-decoded) image
    /// itself claims to be.
    ///
    /// `CGImageSourceCreateWithData` also independently re-confirms this is
    /// AVIF (not merely HEIC or some other ISO-BMFF-family sibling that
    /// happens to share the `ftyp` brand check above) via
    /// `CGImageSourceGetType`. A file whose `meta` box describes an item
    /// but carries no actual coded image data (`CGImageSourceGetCount ==
    /// 0`), or one that carries an animation/image *sequence* with more
    /// than one coded item (`CGImageSourceGetCount > 1` — this pipeline
    /// only ever validates and caches a single still image, never a
    /// multi-frame `avis` sequence), is rejected here rather than
    /// reporting the shell's declared, never-backed-by-real-pixels
    /// dimensions as if they were trustworthy, or silently caching only
    /// this file's first frame as if it were the whole asset.
    private static func avifPrimaryItemDimensions(
        _ data: Data
    ) throws -> (width: Int, height: Int) {
        // The top-level `ftyp` brand pre-filter above is the sole source
        // of `signatureMismatch` for AVIF: it inspects the format's actual
        // magic bytes directly. Everything from here on already knows
        // this file *declares* itself as AVIF, so any way ImageIO fails to
        // make sense of it — an unparseable buffer, an internally
        // inconsistent brand, or a `meta` box describing an item with no
        // backing coded picture data — is this content being malformed,
        // never a "wrong format entirely" signature mismatch.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AssetError.malformedImageData
        }
        guard let sourceType = CGImageSourceGetType(source) as String?,
              sourceType == "public.avif"
        else {
            throw AssetError.malformedImageData
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw AssetError.malformedImageData
        }
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw AssetError.malformedImageData
        }
        return (width, height)
    }

    /// Validates the top-level `ftyp` box's major/compatible brands include
    /// `avif` or `avis`.
    private static func validateFtypBrand(_ data: Data, boxes: [AVIFTopLevelBox]) throws {
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

    /// Not `private`: shared with
    /// `AssetImageValidator+AVIFItemExtents.swift`'s item-extent coverage proof.
    struct AVIFTopLevelBox {
        let type: String
        /// The byte range of this box's *payload* (after its header).
        let range: Range<Data.Index>
    }

    /// Parses a flat sequence of ISO-BMFF boxes within `range`, bounded by
    /// `limit` iterations as a defensive guard against a hostile file
    /// claiming an enormous number of zero-progress boxes.
    /// Resolves a single box's header length and total size (including
    /// that header) from its 32-bit size field, handling the `size32 == 1`
    /// (64-bit extended size) and `size32 == 0` (extends to end of
    /// `range`) special cases. Split out of ``readAVIFTopLevelBoxes(_:range:limit:)``
    /// purely to keep that function's cyclomatic complexity within this
    /// package's limit; carries no state of its own.
    private static func boxHeaderAndSize(
        size32: UInt32,
        offset: Data.Index,
        range: Range<Data.Index>,
        data: Data
    ) throws -> (headerSize: Int, boxSize: Int) {
        if size32 == 1 {
            // 64-bit extended size follows the 4-byte type. Bound this
            // read against `range` itself (not just `data`'s overall
            // bounds), or a box near the end of a narrower sub-range
            // (e.g. a child box list nested inside a larger buffer)
            // could read its size field from bytes belonging to a
            // sibling or parent box outside this range.
            guard offset + 16 <= range.upperBound else {
                throw AssetError.malformedImageData
            }
            guard let size64 = readUInt64BE(data, at: offset + 8) else {
                throw AssetError.malformedImageData
            }
            guard size64 <= UInt64(Int.max) else { throw AssetError.malformedImageData }
            return (16, Int(size64))
        }
        if size32 == 0 {
            // Box extends to the end of the parent range.
            return (8, range.upperBound - offset)
        }
        return (8, Int(size32))
    }

    /// Not `private`: shared with
    /// `AssetImageValidator+AVIFItemExtents.swift`'s item-extent coverage proof
    /// (which also uses it to walk `meta`'s own child box list).
    static func readAVIFTopLevelBoxes(
        _ data: Data,
        range: Range<Data.Index>,
        limit: Int
    ) throws -> [AVIFTopLevelBox] {
        var boxes: [AVIFTopLevelBox] = []
        var offset = range.lowerBound
        var iterations = 0
        while offset + 8 <= range.upperBound {
            iterations += 1
            guard iterations <= limit else { throw AssetError.malformedImageData }
            guard let size32 = readUInt32BE(data, at: offset)
            else { throw AssetError.malformedImageData }
            let (headerSize, boxSize) = try boxHeaderAndSize(
                size32: size32,
                offset: offset,
                range: range,
                data: data
            )
            guard boxSize >= headerSize else {
                throw AssetError.malformedImageData
            }
            // A 64-bit extended `boxSize` can be as large as `Int.max`
            // itself, in which case adding any nonzero `offset` (i.e. any
            // box that is not the very first one read) would silently
            // overflow `Int` and crash the process with a fatal-error trap
            // rather than throwing — turning a hostile file into a denial
            // of service instead of a rejected asset. `addingReportingOverflow`
            // proves the sum is representable before it is ever computed or
            // compared.
            let (boxEnd, overflowed) = offset.addingReportingOverflow(boxSize)
            guard !overflowed, boxEnd <= range.upperBound else {
                throw AssetError.malformedImageData
            }
            guard let type = String(bytes: data[offset + 4 ..< offset + 8], encoding: .utf8) else {
                throw AssetError.malformedImageData
            }
            let payloadRange = (offset + headerSize) ..< boxEnd
            boxes.append(AVIFTopLevelBox(type: type, range: payloadRange))
            offset = boxEnd
        }
        // Every byte of `range` must belong to some complete, fully-parsed
        // box: 1-7 leftover bytes after the last complete box (too few to
        // even hold another box header) is not "no more boxes to read" —
        // it is trailing garbage this parser silently ignored while still
        // reporting the brands it *did* find as trustworthy. Requiring an
        // exact end match closes that gap.
        guard offset == range.upperBound else {
            throw AssetError.malformedImageData
        }
        return boxes
    }
}
