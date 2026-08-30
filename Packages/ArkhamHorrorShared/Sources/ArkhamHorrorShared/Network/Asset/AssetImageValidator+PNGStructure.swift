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
    /// Validates every chunk's container-level structure and returns the
    /// exact concatenated bytes of every `IDAT` chunk's own data (in file
    /// order, excluding each chunk's length/type/CRC framing) -- the
    /// single RFC 1950 zlib datastream the PNG specification requires
    /// their concatenation to form, which
    /// ``validateExactPNGInflation(idatPayload:rowByteCount:rowCount:)`` then
    /// decompresses and checks for an exact byte-count match.
    @discardableResult
    static func validatePNGStructure(_ data: Data) throws -> Data {
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

        while true {
            let chunk = try validatePNGChunk(data, at: offset)

            if isFirstChunk {
                guard chunk.type == "IHDR" else { throw AssetError.malformedImageData }
                isFirstChunk = false
            }
            if chunk.type == "IDAT" {
                guard !idatRunEnded else { throw AssetError.malformedImageData }
                sawIDAT = true
                idatPayload.append(data[chunk.dataRange])
            } else if sawIDAT {
                idatRunEnded = true
            }
            if chunk.type == "IEND" {
                // Strict no-trailing-bytes policy: `IEND` must be the
                // exact final chunk in the buffer, not merely present
                // somewhere before other, ignored trailing data.
                guard chunk.chunkEnd == data.endIndex else { throw AssetError.malformedImageData }
                guard sawIDAT else { throw AssetError.malformedImageData }
                // The PNG specification mandates a zero-byte `IEND`
                // payload. A structurally-invalid file that gives `IEND`
                // a nonempty payload (while still keeping its CRC
                // internally consistent with that payload) can still
                // report a CRC match and reach EOF here, yet ImageIO may
                // still lazily decode *something* from the surrounding
                // stream — never treat that leniency as validation.
                guard chunk.dataRange.isEmpty else { throw AssetError.malformedImageData }
                return idatPayload
            }
            offset = chunk.chunkEnd
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
