import Foundation

/// Strict baseline-JPEG entropy-coded scan decoding, closing the gap
/// `validateJPEGStructure(_:)`'s own marker/length walk deliberately
/// leaves open: that walk only proves *some* non-empty span of bytes
/// between `SOS` and the next real marker exists, correctly skipping
/// byte-stuffed `FF 00` and in-scan restart markers -- it does not prove
/// those bytes are an actually well-formed, fully-consumed Huffman
/// bitstream. A single arbitrary byte of "entropy data" immediately
/// followed by `EOI` already satisfies that walk, and ImageIO's own
/// lazy/best-effort decoder may still silently repair (rather than
/// reject) such a file for a small enough declared size.
///
/// This decodes every MCU's DC/AC Huffman symbols (run-length/category
/// pairs, `RECEIVE`/`EXTEND` magnitude bits, restart-marker resynchronization
/// and DC-predictor resets) exactly as ITU-T.81 Annex F/G describe, without
/// needing dequantization, zigzag placement, or IDCT -- structural/coverage
/// validation only, never producing pixel data of its own (the actual
/// pixel decode remains ImageIO's job, forced eagerly by
/// `AssetImageDecoder`). Baseline sequential (`SOF0`/`SOF1`) only:
/// progressive, lossless, arithmetic-coded, and hierarchical JPEGs are
/// rejected as unsupported, and only a single scan covering every frame
/// component (the only shape ImageIO's own JPEG encoder or any real
/// card-art asset is expected to produce) is accepted -- the same
/// deliberate scope-narrowing already established for Adam7-interlaced
/// PNGs in `AssetImageValidator+PNGZlib.swift`.
extension AssetImageValidator {
    /// A parsed `SOF0`/`SOF1` frame-header component descriptor.
    struct JPEGComponent: Equatable {
        let id: UInt8
        let horizontalSampling: Int
        let verticalSampling: Int
        let quantTableSelector: Int
    }

    /// A parsed, baseline-only `SOF0`/`SOF1` frame header.
    struct JPEGFrameInfo: Equatable {
        let width: Int
        let height: Int
        let components: [JPEGComponent]
    }

    /// A single component's table selectors within a `SOS` scan header.
    struct JPEGScanComponent: Equatable {
        let componentSelector: UInt8
        let dcTableSelector: Int
        let acTableSelector: Int
    }

    /// A canonical Huffman decode table built via the standard JPEG
    /// (ITU-T.81 Annex C) `mincode`/`maxcode`/`valptr` procedure, indexed
    /// by code length 1...16 (index 0 unused/sentinel).
    struct JPEGHuffmanTable {
        let mincode: [Int]
        let maxcode: [Int]
        let valptr: [Int]
        let huffval: [UInt8]
    }

    /// A scan component fully resolved against its matching frame
    /// component and Huffman tables, so the hot MCU-decode loop never
    /// needs to search or optionally-unwrap per block.
    private struct ResolvedComponent {
        let horizontalSampling: Int
        let verticalSampling: Int
        let dcTable: JPEGHuffmanTable
        let acTable: JPEGHuffmanTable
    }

    /// The MCU grid geometry derived from the resolved components' own
    /// sampling factors and the frame's pixel dimensions. A dedicated
    /// struct rather than a tuple purely to keep this package's
    /// tuple-arity convention.
    private struct MCUGeometry {
        let mcusPerLine: Int
        let mcusPerColumn: Int
        let totalMCUs: Int
    }

    /// Builds every `DHT`-declared Huffman table, split by DC/AC class and
    /// keyed by destination.
    private static func buildHuffmanTables(
        _ definitions: [JPEGHuffmanTableDefinition]
    ) throws -> (dc: [Int: JPEGHuffmanTable], ac: [Int: JPEGHuffmanTable]) {
        var dcTables: [Int: JPEGHuffmanTable] = [:]
        var acTables: [Int: JPEGHuffmanTable] = [:]
        for entry in definitions {
            let table = try buildHuffmanTable(counts: entry.counts, values: entry.values)
            if entry.isACTable {
                acTables[entry.destination] = table
            } else {
                dcTables[entry.destination] = table
            }
        }
        return (dcTables, acTables)
    }

    /// Resolves each scan component's matching frame component and
    /// DC/AC Huffman tables, failing if any reference is missing.
    private static func resolveScanComponents(
        _ scanComponents: [JPEGScanComponent],
        frame: JPEGFrameInfo,
        dcTables: [Int: JPEGHuffmanTable],
        acTables: [Int: JPEGHuffmanTable]
    ) throws -> [ResolvedComponent] {
        var resolved: [ResolvedComponent] = []
        resolved.reserveCapacity(scanComponents.count)
        for scanComponent in scanComponents {
            let matchingFrameComponent = frame.components.first {
                $0.id == scanComponent.componentSelector
            }
            guard let frameComponent = matchingFrameComponent,
                  let dcTable = dcTables[scanComponent.dcTableSelector],
                  let acTable = acTables[scanComponent.acTableSelector]
            else {
                throw AssetError.malformedImageData
            }
            resolved.append(
                ResolvedComponent(
                    horizontalSampling: frameComponent.horizontalSampling,
                    verticalSampling: frameComponent.verticalSampling,
                    dcTable: dcTable,
                    acTable: acTable
                )
            )
        }
        return resolved
    }

    /// Computes the MCU grid geometry for `resolved`'s maximum sampling
    /// factors against the frame's own pixel dimensions, guarding against
    /// integer overflow in the MCU-count multiplication.
    private static func computeMCUGeometry(
        resolved: [ResolvedComponent],
        frameWidth: Int,
        frameHeight: Int
    ) throws -> MCUGeometry {
        let maxH = resolved.map(\.horizontalSampling).max() ?? 1
        let maxV = resolved.map(\.verticalSampling).max() ?? 1
        guard maxH > 0, maxV > 0 else { throw AssetError.malformedImageData }
        let mcuWidth = 8 * maxH
        let mcuHeight = 8 * maxV
        let mcusPerLine = (frameWidth + mcuWidth - 1) / mcuWidth
        let mcusPerColumn = (frameHeight + mcuHeight - 1) / mcuHeight
        let (totalMCUs, mcuOverflowed) = mcusPerLine.multipliedReportingOverflow(by: mcusPerColumn)
        guard !mcuOverflowed, totalMCUs > 0 else { throw AssetError.malformedImageData }
        return MCUGeometry(
            mcusPerLine: mcusPerLine,
            mcusPerColumn: mcusPerColumn,
            totalMCUs: totalMCUs
        )
    }

    /// Decodes every MCU's every component's every 8x8 block in raster
    /// order, honoring restart intervals (resetting DC predictors and
    /// consuming cyclic `RSTn` markers at each boundary).
    private static func decodeAllMCUs(
        reader: inout JPEGBitReader,
        resolved: [ResolvedComponent],
        restartInterval: Int,
        totalMCUs: Int
    ) throws {
        var dcPredictors = [Int](repeating: 0, count: resolved.count)
        var mcusSinceRestart = 0
        var nextRestartMarker: UInt8 = 0xD0

        for mcuIndex in 0 ..< totalMCUs {
            if restartInterval > 0, mcuIndex > 0, mcusSinceRestart == restartInterval {
                try reader.consumeRestartMarker(expected: nextRestartMarker)
                nextRestartMarker = nextRestartMarker == 0xD7 ? 0xD0 : nextRestartMarker + 1
                for index in dcPredictors.indices {
                    dcPredictors[index] = 0
                }
                mcusSinceRestart = 0
            }
            for componentIndex in resolved.indices {
                let component = resolved[componentIndex]
                let blockCount = component.horizontalSampling * component.verticalSampling
                guard blockCount > 0, blockCount <= 4 else { throw AssetError.malformedImageData }
                for _ in 0 ..< blockCount {
                    try decodeBlock(
                        reader: &reader,
                        dcTable: component.dcTable,
                        acTable: component.acTable,
                        dcPredictor: &dcPredictors[componentIndex]
                    )
                }
            }
            mcusSinceRestart += 1
        }
    }

    /// The full set of already-parsed inputs
    /// ``validateJPEGEntropyCoverage(_:scan:)`` needs to decode and
    /// verify a single entropy-coded scan. A dedicated struct rather
    /// than five separate parameters purely to keep that function's own
    /// parameter count within this package's convention.
    struct JPEGEntropyScanInput {
        let frame: JPEGFrameInfo
        let scanComponents: [JPEGScanComponent]
        let huffmanTables: [JPEGHuffmanTableDefinition]
        let restartInterval: Int
        let entropyRange: Range<Int>
    }

    /// Validates that `data`'s single entropy-coded scan (already located,
    /// as `scan.entropyRange`, by `validateJPEGStructure(_:)`'s own marker
    /// walk) decodes to exactly one full raster of MCUs for the
    /// already-parsed frame -- consuming every declared restart interval's
    /// worth of MCUs between resynchronization markers, every component's
    /// full sampling-factor block count per MCU, and leaving no
    /// unconsumed real bytes (only, at most, the standard all-1s
    /// bit-padding of the final partial byte) before `scan.entropyRange`'s
    /// own end.
    static func validateJPEGEntropyCoverage(
        _ data: Data,
        scan: JPEGEntropyScanInput
    ) throws {
        guard !scan.frame.components.isEmpty, scan.frame.components.count <= 4 else {
            throw AssetError.malformedImageData
        }
        guard scan.scanComponents.count == scan.frame.components.count else {
            // Only a single scan covering every frame component
            // (interleaved) is in scope; a multi-scan (non-interleaved)
            // baseline JPEG is technically legal but never produced by
            // ImageIO and is rejected as unsupported.
            throw AssetError.malformedImageData
        }
        // Beyond a matching *count*, the scan's own selector *set* must
        // be exactly the frame's component ID set: with both this and
        // ``parseJPEGFrameHeader``'s own frame-component-ID uniqueness
        // guard already established, an equal-size selector set that
        // also equals the frame's ID set is the only way every frame
        // component is scanned exactly once. Without this, a scan
        // selector list with a duplicate (e.g. `[1, 1, 1]` against a
        // 3-component frame `[1, 2, 3]`) would still pass the count
        // check, decode successfully by repeatedly resolving component 1
        // three times, and leave components 2 and 3 completely
        // undecoded/unverified by this coverage proof despite reporting
        // success for the whole image.
        guard
            Set(scan.scanComponents.map(\.componentSelector))
            == Set(scan.frame.components.map(\.id))
        else {
            throw AssetError.malformedImageData
        }

        let tables = try buildHuffmanTables(scan.huffmanTables)
        let resolved = try resolveScanComponents(
            scan.scanComponents,
            frame: scan.frame,
            dcTables: tables.dc,
            acTables: tables.ac
        )
        let geometry = try computeMCUGeometry(
            resolved: resolved,
            frameWidth: scan.frame.width,
            frameHeight: scan.frame.height
        )

        var reader = JPEGBitReader(
            data: data,
            start: scan.entropyRange.lowerBound,
            end: scan.entropyRange.upperBound
        )
        try decodeAllMCUs(
            reader: &reader,
            resolved: resolved,
            restartInterval: scan.restartInterval,
            totalMCUs: geometry.totalMCUs
        )

        try reader.requireExhaustedAtEnd()
    }
}
