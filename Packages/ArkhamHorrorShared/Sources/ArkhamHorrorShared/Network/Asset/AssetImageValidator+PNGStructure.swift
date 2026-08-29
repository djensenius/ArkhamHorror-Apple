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
/// first chunk is `IHDR`; at least one `IDAT` chunk is present; the file
/// ends with a critical `IEND` chunk and not a single byte of trailing
/// data after it; and every chunk's declared CRC-32 (over its own type and
/// data, exactly as the PNG specification defines it) matches what its
/// bytes actually checksum to — the same mechanism that would catch a
/// `IDAT` truncated or corrupted mid-stream, since removing or altering
/// even one byte changes that chunk's checksum.
extension AssetImageValidator {
    static func validatePNGStructure(_ data: Data) throws {
        var offset = data.startIndex + 8 // past the 8-byte signature
        var sawIDAT = false
        // PNG requires every `IDAT` chunk to appear consecutively, with no
        // other chunk type interposed between them — a file with `IDAT`
        // chunks split apart by an intervening (even CRC-valid) ancillary
        // chunk is not a spec-conforming PNG and must not be trusted, even
        // though each individual chunk's own CRC still checks out.
        var idatRunEnded = false
        var isFirstChunk = true

        while true {
            let (chunkEnd, type) = try validatePNGChunk(data, at: offset)

            if isFirstChunk {
                guard type == "IHDR" else { throw AssetError.malformedImageData }
                isFirstChunk = false
            }
            if type == "IDAT" {
                guard !idatRunEnded else { throw AssetError.malformedImageData }
                sawIDAT = true
            } else if sawIDAT {
                idatRunEnded = true
            }
            if type == "IEND" {
                // Strict no-trailing-bytes policy: `IEND` must be the
                // exact final chunk in the buffer, not merely present
                // somewhere before other, ignored trailing data.
                guard chunkEnd == data.endIndex else { throw AssetError.malformedImageData }
                guard sawIDAT else { throw AssetError.malformedImageData }
                return
            }
            offset = chunkEnd
        }
    }

    /// Validates a single PNG chunk starting at `offset` — its declared
    /// length, its type field is valid ASCII, and its CRC-32 matches —
    /// returning the offset just past it and its 4-character type.
    /// Factored out of ``validatePNGStructure(_:)`` purely to keep that
    /// function's own cyclomatic complexity within this package's
    /// convention.
    private static func validatePNGChunk(
        _ data: Data,
        at offset: Int
    ) throws -> (chunkEnd: Int, type: String) {
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
        return (crcStart + 4, type)
    }
}
