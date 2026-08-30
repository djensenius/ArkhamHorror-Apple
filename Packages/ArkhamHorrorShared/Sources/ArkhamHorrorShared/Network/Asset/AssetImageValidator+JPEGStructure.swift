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
///
/// Individual segment-field parsers (`SOF`/`DHT`/`DRI`/`SOS` payload
/// layout, marker/segment navigation) live in
/// `AssetImageValidator+JPEGSegments.swift`, split out purely to keep this
/// file within this package's file-length convention.
extension AssetImageValidator {
    /// A single parsed Huffman table definition from a `DHT` segment. A
    /// dedicated struct rather than a tuple purely to keep this package's
    /// tuple-arity convention. Not `private`: shared with
    /// `AssetImageValidator+JPEGEntropy.swift`'s
    /// `validateJPEGEntropyCoverage`.
    struct JPEGHuffmanTableDefinition {
        let isACTable: Bool
        let destination: Int
        let counts: [Int]
        let values: [UInt8]
    }

    /// A single parsed quantization table definition from a `DQT`
    /// segment. Not `private`: shared with
    /// `AssetImageValidator+JPEGSegments.swift`'s
    /// `parseJPEGQuantizationTables`.
    struct JPEGQuantizationTableDefinition {
        let destination: Int
        let precision: Int
        let values: [Int]
    }

    /// Mutable marker-walk state threaded through
    /// ``validateJPEGStructure(_:expectedWidth:expectedHeight:)``, bundled
    /// into a single struct purely to keep that function's own (and its
    /// helpers') parameter counts within this package's convention.
    private struct JPEGParserState {
        var sawSOF = false
        var sawScanData = false
        var sawSOS = false
        var frame: JPEGFrameInfo?
        var huffmanTables: [JPEGHuffmanTableDefinition] = []
        var quantizationTableDestinations: Set<Int> = []
        var restartInterval = 0
    }

    /// The single frame's expected pixel dimensions, as already
    /// established by ``AssetImageValidator``'s own pure first-`SOF`
    /// dimension parse -- bundled into a struct purely to keep
    /// `handleFrameHeaderMarker`'s own parameter count within this
    /// package's convention.
    private struct JPEGExpectedDimensions {
        let width: Int
        let height: Int
    }

    static func validateJPEGStructure(
        _ data: Data,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws {
        var offset = data.startIndex + 2 // past the 2-byte SOI
        let end = data.endIndex
        var state = JPEGParserState()
        let expectedDimensions = JPEGExpectedDimensions(
            width: expectedWidth,
            height: expectedHeight
        )

        while true {
            let (markerOffset, marker) = try nextMarker(data, from: offset, end: end)

            if marker == 0xD9 {
                try requireTerminalEOI(
                    markerOffset: markerOffset,
                    end: end,
                    sawSOF: state.sawSOF,
                    sawScanData: state.sawScanData
                )
                return
            }
            if marker == 0x01 || (0xD0 ... 0xD7).contains(marker) {
                // TEM or a stray restart marker outside a scan: no
                // length field; simply continue.
                offset = markerOffset + 1
                continue
            }

            offset = try handleLengthPrefixedMarker(
                data,
                location: JPEGMarkerLocation(marker: marker, offset: markerOffset),
                end: end,
                expected: expectedDimensions,
                state: &state
            )
        }
    }

    /// A marker byte together with the buffer offset it was found at,
    /// bundled into a struct purely to keep
    /// ``handleLengthPrefixedMarker(_:location:end:expected:state:)``'s
    /// own parameter count within this package's convention.
    private struct JPEGMarkerLocation {
        let marker: UInt8
        let offset: Int
    }

    /// Handles every marker that carries its own 2-byte segment length
    /// (every marker except `SOI`/`EOI`/`TEM`/in-scan restart markers,
    /// all already handled directly by the main loop): computes the
    /// segment's end, dispatches frame-header/table-definition/
    /// start-of-scan handling as appropriate, and returns the offset to
    /// resume the marker walk from. Factored out of
    /// ``validateJPEGStructure(_:expectedWidth:expectedHeight:)`` purely
    /// to keep that function's own body length within this package's
    /// convention.
    private static func handleLengthPrefixedMarker(
        _ data: Data,
        location: JPEGMarkerLocation,
        end: Int,
        expected: JPEGExpectedDimensions,
        state: inout JPEGParserState
    ) throws -> Int {
        let marker = location.marker
        let markerOffset = location.offset
        let segmentEnd = try jpegSegmentEnd(data, markerOffset: markerOffset, end: end)
        if jpegSOFMarkers.contains(marker) {
            state.frame = try handleFrameHeaderMarker(
                data,
                marker: marker,
                markerOffset: markerOffset,
                segmentEnd: segmentEnd,
                expected: expected
            )
            state.sawSOF = true
        }
        if marker == 0xC4 || marker == 0xDD || marker == 0xDB {
            try handleTableDefinitionMarker(
                data,
                marker: marker,
                markerOffset: markerOffset,
                segmentEnd: segmentEnd,
                state: &state
            )
        }
        if marker == 0xDA {
            return try handleScanMarker(
                data,
                markerOffset: markerOffset,
                segmentEnd: segmentEnd,
                end: end,
                state: &state
            )
        }
        return segmentEnd
    }

    /// Handles a `DHT` (Huffman table definitions), `DQT` (quantization
    /// table definitions), or `DRI` (restart interval) marker reached by
    /// the main marker walk, merging every already-parsed result into
    /// `state`. Factored out of
    /// ``validateJPEGStructure(_:expectedWidth:expectedHeight:)`` purely
    /// to keep that function's own body length within this package's
    /// convention.
    private static func handleTableDefinitionMarker(
        _ data: Data,
        marker: UInt8,
        markerOffset: Int,
        segmentEnd: Int,
        state: inout JPEGParserState
    ) throws {
        if marker == 0xC4 {
            let tables = try parseJPEGHuffmanTables(
                data,
                markerOffset: markerOffset,
                segmentEnd: segmentEnd
            )
            state.huffmanTables.append(contentsOf: tables)
        } else if marker == 0xDB {
            let tables = try parseJPEGQuantizationTables(
                data,
                markerOffset: markerOffset,
                segmentEnd: segmentEnd
            )
            for table in tables {
                state.quantizationTableDestinations.insert(table.destination)
            }
        } else {
            state.restartInterval = try parseJPEGRestartInterval(
                data,
                markerOffset: markerOffset,
                segmentEnd: segmentEnd
            )
        }
    }

    /// Handles a `SOS` marker reached by the main marker walk: rejects a
    /// second scan (only a single interleaved scan is in scope), then
    /// delegates to ``handleStartOfScan(_:markerOffset:segmentEnd:end:state:)``
    /// and updates `state` to reflect that real scan data was consumed.
    /// Factored out of
    /// ``validateJPEGStructure(_:expectedWidth:expectedHeight:)`` purely
    /// to keep that function's own body length within this package's
    /// convention.
    private static func handleScanMarker(
        _ data: Data,
        markerOffset: Int,
        segmentEnd: Int,
        end: Int,
        state: inout JPEGParserState
    ) throws -> Int {
        guard !state.sawSOS else {
            // Only a single scan (interleaved, covering every frame
            // component) is in scope; a legal-but-never-ImageIO-produced
            // multi-scan baseline JPEG is rejected as unsupported.
            throw AssetError.malformedImageData
        }
        state.sawSOS = true
        let entropyEnd = try handleStartOfScan(
            data,
            markerOffset: markerOffset,
            segmentEnd: segmentEnd,
            end: end,
            state: state
        )
        state.sawScanData = true
        return entropyEnd
    }

    /// Validates a `SOF` marker is a supported baseline/extended-
    /// sequential variant, parses its frame header, and cross-checks the
    /// result against the already-validated pure dimension parse. Factored
    /// out of ``validateJPEGStructure(_:expectedWidth:expectedHeight:)``
    /// purely to keep that function's own cyclomatic complexity and body
    /// length within this package's convention.
    private static func handleFrameHeaderMarker(
        _ data: Data,
        marker: UInt8,
        markerOffset: Int,
        segmentEnd: Int,
        expected: JPEGExpectedDimensions
    ) throws -> JPEGFrameInfo {
        // Baseline sequential (`SOF0`) and extended-sequential Huffman
        // (`SOF1`) are the only frame types this strict entropy decoder
        // understands; every other `SOF` variant (progressive, lossless,
        // arithmetic-coded, hierarchical) is rejected as unsupported
        // rather than risk silently mis-validating a coding structure
        // this decoder cannot actually walk.
        guard marker == 0xC0 || marker == 0xC1 else {
            throw AssetError.malformedImageData
        }
        let frame = try parseJPEGFrameHeader(
            data,
            markerOffset: markerOffset,
            segmentEnd: segmentEnd
        )
        guard frame.width == expected.width, frame.height == expected.height else {
            // Cross-check against the already-validated pure dimension
            // parse: must be the exact same frame.
            throw AssetError.malformedImageData
        }
        return frame
    }

    /// Validates a `SOS` segment's own header against the already-parsed
    /// frame, locates and validates its entropy-coded scan data, and
    /// returns the offset immediately past that entropy data. Factored
    /// out of ``validateJPEGStructure(_:expectedWidth:expectedHeight:)``
    /// purely to keep that function's own cyclomatic complexity and body
    /// length within this package's convention.
    private static func handleStartOfScan(
        _ data: Data,
        markerOffset: Int,
        segmentEnd: Int,
        end: Int,
        state: JPEGParserState
    ) throws -> Int {
        guard let frame = state.frame else { throw AssetError.malformedImageData }
        // Every frame component's own quantization-table selector
        // (parsed and range-checked when the `SOF` header itself was
        // read) must actually resolve to a table a `DQT` segment
        // defined somewhere before this scan begins -- a selector with
        // no corresponding definition can never be legitimately produced
        // by a real encoder and would otherwise silently dequantize
        // using whatever undefined/zeroed table state ImageIO's own
        // decoder happens to substitute.
        for component in frame.components {
            guard state.quantizationTableDestinations.contains(component.quantTableSelector) else {
                throw AssetError.malformedImageData
            }
        }
        let scanComponents = try parseJPEGScanHeader(
            data,
            markerOffset: markerOffset,
            segmentEnd: segmentEnd
        )
        // Start-of-scan: its own header ends at `segmentEnd`; entropy-
        // coded data begins there and continues until the next real
        // (non-stuffed, non-restart) marker.
        let entropyEnd = try scanEntropyData(data, from: segmentEnd, end: end)
        try validateJPEGEntropyCoverage(
            data,
            scan: JPEGEntropyScanInput(
                frame: frame,
                scanComponents: scanComponents,
                huffmanTables: state.huffmanTables,
                restartInterval: state.restartInterval,
                entropyRange: segmentEnd ..< entropyEnd
            )
        )
        return entropyEnd
    }
}
