import Foundation

extension AssetImageValidator {
    // MARK: - AVIF (ISO-BMFF)

    /// Walks top-level ISO-BMFF boxes looking for `ftyp` (validating the
    /// `avif`/`avis` brand) and then `meta` → `iprp` → `ipco` → the first
    /// `ispe` box (4-byte version/flags, then big-endian width/height).
    /// Every box header is bounds-checked against the remaining buffer, and
    /// box walking only moves forward, so a hostile box size cannot cause
    /// an out-of-bounds read or an infinite loop.
    /// Not `private`: called from the main format dispatch in
    /// `AssetImageValidator.swift`.
    static func parseAVIFDimensions(_ data: Data) throws -> (width: Int, height: Int) {
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
        // Bound the read against `ispe.range` itself (not just `data`'s
        // overall bounds), or a truncated box could read into a following
        // box's bytes and report bogus-but-plausible dimensions.
        guard payloadStart + 8 <= ispe.range.upperBound else {
            throw AssetError.malformedImageData
        }
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
}
