import Foundation

/// Individual JPEG marker-segment field parsers and marker/segment
/// navigation helpers used by
/// ``AssetImageValidator/validateJPEGStructure(_:expectedWidth:expectedHeight:)``.
/// Split out of `AssetImageValidator+JPEGStructure.swift` purely to keep
/// that file within this package's file-length convention.
extension AssetImageValidator {
    /// Parses a baseline (`SOF0`/`SOF1`) frame header's precision,
    /// height, width, and per-component sampling/quant-table descriptors.
    /// Only 8-bit precision is accepted (ImageIO's own JPEG encoder never
    /// produces 12-bit extended-sequential frames, and this decoder's
    /// Huffman/`RECEIVE` logic assumes 8-bit sample precision throughout).
    static func parseJPEGFrameHeader(
        _ data: Data,
        markerOffset: Int,
        segmentEnd: Int
    ) throws -> JPEGFrameInfo {
        let payloadOffset = markerOffset + 3
        guard payloadOffset + 6 <= segmentEnd,
              let height = readUInt16BE(data, at: payloadOffset + 1),
              let width = readUInt16BE(data, at: payloadOffset + 3)
        else {
            throw AssetError.malformedImageData
        }
        let precision = data[payloadOffset]
        guard precision == 8 else { throw AssetError.malformedImageData }
        guard width > 0, height > 0 else { throw AssetError.malformedImageData }

        let componentCountOffset = payloadOffset + 5
        guard componentCountOffset < segmentEnd else { throw AssetError.malformedImageData }
        let componentCount = Int(data[componentCountOffset])
        guard componentCount >= 1, componentCount <= 4 else { throw AssetError.malformedImageData }

        var components: [JPEGComponent] = []
        components.reserveCapacity(componentCount)
        var componentOffset = componentCountOffset + 1
        for _ in 0 ..< componentCount {
            guard componentOffset + 3 <= segmentEnd else { throw AssetError.malformedImageData }
            let id = data[componentOffset]
            let samplingByte = data[componentOffset + 1]
            let quantTableSelector = Int(data[componentOffset + 2])
            let horizontalSampling = Int(samplingByte >> 4)
            let verticalSampling = Int(samplingByte & 0x0F)
            guard (1 ... 4).contains(horizontalSampling),
                  (1 ... 4).contains(verticalSampling)
            else {
                throw AssetError.malformedImageData
            }
            guard quantTableSelector <= 3 else { throw AssetError.malformedImageData }
            components.append(
                JPEGComponent(
                    id: id,
                    horizontalSampling: horizontalSampling,
                    verticalSampling: verticalSampling,
                    quantTableSelector: quantTableSelector
                )
            )
            componentOffset += 3
        }
        guard componentOffset == segmentEnd else { throw AssetError.malformedImageData }

        return JPEGFrameInfo(width: Int(width), height: Int(height), components: components)
    }

    /// Parses every Huffman table definition within a single `DHT`
    /// segment (which may concatenate more than one class/destination
    /// table back to back).
    static func parseJPEGHuffmanTables(
        _ data: Data,
        markerOffset: Int,
        segmentEnd: Int
    ) throws -> [JPEGHuffmanTableDefinition] {
        var tables: [JPEGHuffmanTableDefinition] = []
        var offset = markerOffset + 3 // past marker + 2-byte length
        while offset < segmentEnd {
            guard offset + 17 <= segmentEnd else { throw AssetError.malformedImageData }
            let classAndDestination = data[offset]
            let isACTable = (classAndDestination >> 4) == 1
            guard (classAndDestination >> 4) <= 1 else { throw AssetError.malformedImageData }
            let destination = Int(classAndDestination & 0x0F)
            guard destination <= 3 else { throw AssetError.malformedImageData }

            var counts: [Int] = []
            counts.reserveCapacity(16)
            var totalSymbols = 0
            for lengthIndex in 0 ..< 16 {
                let count = Int(data[offset + 1 + lengthIndex])
                counts.append(count)
                totalSymbols += count
            }
            guard totalSymbols > 0, totalSymbols <= 256 else {
                throw AssetError.malformedImageData
            }

            let valuesStart = offset + 17
            guard valuesStart + totalSymbols <= segmentEnd else {
                throw AssetError.malformedImageData
            }
            let values = Array(data[valuesStart ..< valuesStart + totalSymbols])

            tables.append(
                JPEGHuffmanTableDefinition(
                    isACTable: isACTable,
                    destination: destination,
                    counts: counts,
                    values: values
                )
            )
            offset = valuesStart + totalSymbols
        }
        guard offset == segmentEnd else { throw AssetError.malformedImageData }
        return tables
    }

    /// Parses a `DRI` segment's 2-byte restart-interval value (MCUs
    /// between restart markers; `0` disables restart intervals).
    static func parseJPEGRestartInterval(
        _ data: Data,
        markerOffset: Int,
        segmentEnd: Int
    ) throws -> Int {
        let payloadOffset = markerOffset + 3
        guard payloadOffset + 2 == segmentEnd,
              let interval = readUInt16BE(data, at: payloadOffset)
        else {
            throw AssetError.malformedImageData
        }
        return Int(interval)
    }

    /// Parses every quantization-table definition within a single `DQT`
    /// segment (which, like `DHT`, may concatenate more than one
    /// destination table back to back): each table's own precision
    /// (`Pq`, 0 for 8-bit or 1 for 16-bit coefficients) and destination
    /// (`Tq`, 0-3), followed by exactly 64 coefficients (1 byte each for
    /// `Pq == 0`, 2 big-endian bytes each for `Pq == 1`). Per the JPEG
    /// specification (and every real encoder, including ImageIO's), a
    /// quantization coefficient of exactly zero is illegal -- it would
    /// make dequantization multiply by zero and permanently destroy that
    /// coefficient -- so this rejects any table containing one rather
    /// than silently accepting whatever ImageIO's own decoder happens to
    /// repair it into.
    static func parseJPEGQuantizationTables(
        _ data: Data,
        markerOffset: Int,
        segmentEnd: Int
    ) throws -> [JPEGQuantizationTableDefinition] {
        var tables: [JPEGQuantizationTableDefinition] = []
        var offset = markerOffset + 3 // past marker + 2-byte length
        while offset < segmentEnd {
            guard offset + 1 <= segmentEnd else { throw AssetError.malformedImageData }
            let precisionAndDestination = data[offset]
            let precision = Int(precisionAndDestination >> 4)
            guard precision == 0 || precision == 1 else { throw AssetError.malformedImageData }
            let destination = Int(precisionAndDestination & 0x0F)
            guard destination <= 3 else { throw AssetError.malformedImageData }

            let coefficientByteWidth = precision == 0 ? 1 : 2
            let coefficientsStart = offset + 1
            let coefficientsEnd = coefficientsStart + 64 * coefficientByteWidth
            guard coefficientsEnd <= segmentEnd else { throw AssetError.malformedImageData }

            var values: [Int] = []
            values.reserveCapacity(64)
            var coefficientOffset = coefficientsStart
            for _ in 0 ..< 64 {
                let value: Int
                if precision == 0 {
                    value = Int(data[coefficientOffset])
                } else {
                    guard let wide = readUInt16BE(data, at: coefficientOffset) else {
                        throw AssetError.malformedImageData
                    }
                    value = Int(wide)
                }
                guard value != 0 else { throw AssetError.malformedImageData }
                values.append(value)
                coefficientOffset += coefficientByteWidth
            }

            tables.append(
                JPEGQuantizationTableDefinition(
                    destination: destination,
                    precision: precision,
                    values: values
                )
            )
            offset = coefficientsEnd
        }
        guard offset == segmentEnd else { throw AssetError.malformedImageData }
        return tables
    }

    /// Parses a `SOS` segment header's per-component DC/AC table
    /// selectors and requires baseline-sequential-only spectral
    /// selection (full range, no successive approximation) -- always
    /// true for an `SOF0`/`SOF1` frame's own scan, but validated
    /// explicitly rather than assumed.
    static func parseJPEGScanHeader(
        _ data: Data,
        markerOffset: Int,
        segmentEnd: Int
    ) throws -> [JPEGScanComponent] {
        let payloadOffset = markerOffset + 3
        guard payloadOffset < segmentEnd else { throw AssetError.malformedImageData }
        let componentCount = Int(data[payloadOffset])
        guard componentCount >= 1, componentCount <= 4 else { throw AssetError.malformedImageData }

        var components: [JPEGScanComponent] = []
        components.reserveCapacity(componentCount)
        var componentOffset = payloadOffset + 1
        for _ in 0 ..< componentCount {
            guard componentOffset + 2 <= segmentEnd else { throw AssetError.malformedImageData }
            let selector = data[componentOffset]
            let tableSelectors = data[componentOffset + 1]
            components.append(
                JPEGScanComponent(
                    componentSelector: selector,
                    dcTableSelector: Int(tableSelectors >> 4),
                    acTableSelector: Int(tableSelectors & 0x0F)
                )
            )
            componentOffset += 2
        }

        guard componentOffset + 3 == segmentEnd else { throw AssetError.malformedImageData }
        let spectralStart = Int(data[componentOffset])
        let spectralEnd = Int(data[componentOffset + 1])
        let approx = data[componentOffset + 2]
        guard spectralStart == 0, spectralEnd == 63, approx == 0 else {
            throw AssetError.malformedImageData
        }

        return components
    }

    /// Finds the next marker starting at or after `offset` (which must
    /// itself be the position of an `0xFF` prefix byte), skipping any
    /// `0xFF` fill bytes between the prefix and the actual marker byte.
    /// Returns the marker byte's own offset and value.
    static func nextMarker(
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
    static func requireTerminalEOI(
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
    static func jpegSegmentEnd(_ data: Data, markerOffset: Int, end: Int) throws -> Int {
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
    static func scanEntropyData(_ data: Data, from start: Int, end: Int) throws -> Int {
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
            break
        }
        guard index < end else {
            // Ran off the end of the buffer while still inside
            // entropy-coded scan data, with no terminating marker (not
            // even `EOI`) at all.
            throw AssetError.malformedImageData
        }
        // A start-of-scan segment immediately followed by a real marker —
        // zero bytes of entropy-coded data at all (for example `SOS`
        // directly followed by `EOI`) — is not a legitimate scan: ImageIO
        // itself may still lazily/leniently decode such a truncated file
        // for a small enough declared size, but no real compressed image
        // data was ever actually present. Requiring strictly more than
        // zero bytes here is what makes `sawScanData` (checked by
        // ``requireTerminalEOI(markerOffset:end:sawSOF:sawScanData:)``)
        // an honest claim that *some* entropy-coded content, not merely a
        // scan *header*, was found.
        guard index > start else {
            throw AssetError.malformedImageData
        }
        return index
    }
}
