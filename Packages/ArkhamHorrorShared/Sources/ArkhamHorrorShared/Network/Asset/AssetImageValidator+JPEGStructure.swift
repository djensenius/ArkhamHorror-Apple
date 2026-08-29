import Foundation

/// Full JPEG marker/entropy-stream structure validation, beyond
/// ``AssetImageValidator``'s pure first-`SOF`-only dimension parse.
///
/// A truncated JPEG (cut off partway through its entropy-coded scan data)
/// can still declare a perfectly valid `SOF` segment and even still
/// successfully produce *a* `CGImage` from ImageIO's lazy, best-effort
/// decoder for a small enough image — the same unreliable-completeness
/// problem ``validatePNGStructure(_:)`` documents for PNG. This walks every
/// marker segment from the `SOI`, requiring: at least one start-of-frame
/// segment; at least one start-of-scan (`SOS`) segment whose
/// entropy-coded data (correctly skipping byte-stuffed `FF 00` and
/// in-scan restart markers `FFD0`-`FFD7`, neither of which terminate a
/// scan) is actually followed by a real marker; and a terminal `EOI`
/// (`FFD9`) marker that is the exact last two bytes of the buffer, not
/// merely present somewhere before other, ignored trailing data.
extension AssetImageValidator {
    static func validateJPEGStructure(_ data: Data) throws {
        var offset = data.startIndex + 2 // past the 2-byte SOI
        let end = data.endIndex
        var sawSOF = false
        var sawScanData = false

        while true {
            let (markerOffset, marker) = try nextMarker(data, from: offset, end: end)

            if marker == 0xD9 {
                try requireTerminalEOI(
                    markerOffset: markerOffset,
                    end: end,
                    sawSOF: sawSOF,
                    sawScanData: sawScanData
                )
                return
            }
            if marker == 0x01 || (0xD0 ... 0xD7).contains(marker) {
                // TEM or a stray restart marker outside a scan: no
                // length field; simply continue.
                offset = markerOffset + 1
                continue
            }

            let segmentEnd = try jpegSegmentEnd(data, markerOffset: markerOffset, end: end)
            if jpegSOFMarkers.contains(marker) {
                sawSOF = true
            }
            if marker == 0xDA {
                // Start-of-scan: its own header ends at `segmentEnd`;
                // entropy-coded data begins there and continues until the
                // next real (non-stuffed, non-restart) marker.
                offset = try scanEntropyData(data, from: segmentEnd, end: end)
                sawScanData = true
                continue
            }
            offset = segmentEnd
        }
    }

    /// Finds the next marker starting at or after `offset` (which must
    /// itself be the position of an `0xFF` prefix byte), skipping any
    /// `0xFF` fill bytes between the prefix and the actual marker byte.
    /// Returns the marker byte's own offset and value.
    private static func nextMarker(
        _ data: Data,
        from offset: Int,
        end: Int
    ) throws -> (markerOffset: Int, marker: UInt8) {
        guard offset + 1 < end, data[offset] == 0xFF else {
            throw AssetError.malformedImageData
        }
        var markerOffset = offset + 1
        while markerOffset < end, data[markerOffset] == 0xFF {
            markerOffset += 1
        }
        guard markerOffset < end else { throw AssetError.malformedImageData }
        return (markerOffset, data[markerOffset])
    }

    /// Validates that an `EOI` marker at `markerOffset` is the file's
    /// exact final byte (strict no-trailing-bytes policy) and that real
    /// frame and scan data were both already seen — an `EOI` reached
    /// before any `SOS` (or any `SOF`) is not a legitimate terminator.
    private static func requireTerminalEOI(
        markerOffset: Int,
        end: Int,
        sawSOF: Bool,
        sawScanData: Bool
    ) throws {
        guard markerOffset == end - 1 else { throw AssetError.malformedImageData }
        guard sawSOF, sawScanData else { throw AssetError.malformedImageData }
    }

    /// Reads a non-SOI/EOI/TEM/restart marker's own declared 2-byte
    /// big-endian segment length (which starts immediately after the
    /// marker byte and includes its own 2 bytes) and returns the offset
    /// immediately past this whole segment.
    private static func jpegSegmentEnd(_ data: Data, markerOffset: Int, end: Int) throws -> Int {
        let lengthOffset = markerOffset + 1
        guard lengthOffset + 1 < end,
              let segmentLength = readUInt16BE(data, at: lengthOffset)
        else {
            throw AssetError.malformedImageData
        }
        guard segmentLength >= 2, lengthOffset + Int(segmentLength) <= end else {
            throw AssetError.malformedImageData
        }
        return lengthOffset + Int(segmentLength)
    }

    /// Skips forward from `start` (the first byte of entropy-coded scan
    /// data, immediately after a start-of-scan segment's own header) past
    /// every byte-stuffed `FF 00` and in-scan restart marker (`FFD0`-
    /// `FFD7`, which restart the entropy coder but never terminate a
    /// scan), returning the offset of the next real marker prefix (an
    /// `0xFF` byte that is followed by neither `0x00` nor a restart
    /// marker).
    private static func scanEntropyData(_ data: Data, from start: Int, end: Int) throws -> Int {
        var index = start
        while index < end {
            guard data[index] == 0xFF else {
                index += 1
                continue
            }
            guard index + 1 < end else {
                // A trailing lone `0xFF` with nothing after it to
                // disambiguate stuffing from a real marker: truncated.
                throw AssetError.malformedImageData
            }
            let next = data[index + 1]
            if next == 0x00 {
                // Byte-stuffed literal `0xFF` within the entropy stream.
                index += 2
                continue
            }
            if (0xD0 ... 0xD7).contains(next) {
                // In-scan restart marker: does not terminate the scan.
                index += 2
                continue
            }
            // A real marker: entropy data for this scan ends here.
            return index
        }
        // Ran off the end of the buffer while still inside entropy-coded
        // scan data, with no terminating marker (not even `EOI`) at all.
        throw AssetError.malformedImageData
    }
}
