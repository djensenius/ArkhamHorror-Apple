import Foundation

/// Low-level baseline-JPEG Huffman decode primitives (canonical
/// mincode/maxcode/valptr table construction, DECODE/RECEIVE/EXTEND,
/// and one full 8x8 block's DC/AC symbol decode) plus the underlying
/// bit-level entropy-stream reader, used by
/// `AssetImageValidator+JPEGEntropy.swift`'s
/// `validateJPEGEntropyCoverage`. Split out purely to keep that file
/// within this package's file-length convention.
extension AssetImageValidator {
    /// Decodes one full 8x8 block's worth of DC/AC Huffman symbols
    /// (updating `dcPredictor` in place), consuming exactly the bits
    /// ITU-T.81 Figure F.12/F.13 (`DECODE`/`RECEIVE`/`EXTEND`) specify --
    /// never storing or dequantizing coefficients, since only bitstream
    /// coverage (not reconstructed pixel values) is being validated here.
    static func decodeBlock(
        reader: inout JPEGBitReader,
        dcTable: JPEGHuffmanTable,
        acTable: JPEGHuffmanTable,
        dcPredictor: inout Int
    ) throws {
        let dcCategory = try huffmanDecode(reader: &reader, table: dcTable)
        guard dcCategory <= 15 else { throw AssetError.malformedImageData }
        let dcDiff: Int = if dcCategory == 0 {
            0
        } else {
            try extend(receive(reader: &reader, count: dcCategory), dcCategory)
        }
        dcPredictor += dcDiff

        var coefficientIndex = 1
        while coefficientIndex <= 63 {
            let runSize = try huffmanDecode(reader: &reader, table: acTable)
            let run = runSize >> 4
            let size = runSize & 0xF
            if size == 0 {
                if run == 15 {
                    // ZRL: 16 zero coefficients, no value bits.
                    coefficientIndex += 16
                    continue
                }
                if run == 0 {
                    // EOB: every remaining coefficient in this block is
                    // implicitly zero.
                    break
                }
                // Any other (run, size=0) pairing is only meaningful in
                // progressive-mode AC refinement scans (EOBn runs), never
                // in a baseline sequential scan.
                throw AssetError.malformedImageData
            }
            coefficientIndex += run
            guard coefficientIndex <= 63 else { throw AssetError.malformedImageData }
            _ = try extend(receive(reader: &reader, count: size), size)
            coefficientIndex += 1
        }
    }

    /// ITU-T.81 Figure F.12 `EXTEND`: recovers a signed magnitude from an
    /// unsigned `count`-bit two's-complement-like coded value.
    private static func extend(_ value: Int, _ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let halfRange = 1 << (count - 1)
        return value < halfRange ? value - (1 << count) + 1 : value
    }

    /// ITU-T.81 Figure F.17 `RECEIVE`: reads `count` bits MSB-first as an
    /// unsigned integer.
    private static func receive(reader: inout JPEGBitReader, count: Int) throws -> Int {
        guard count >= 0, count <= 16 else { throw AssetError.malformedImageData }
        var value = 0
        for _ in 0 ..< count {
            value = try (value << 1) | (reader.nextBit())
        }
        return value
    }

    /// ITU-T.81 Figure F.16 `DECODE`: walks bit-by-bit, growing the
    /// candidate code by one bit at a time, until it falls within the
    /// current length's `[mincode, maxcode]` range, then looks up the
    /// decoded symbol via `valptr`.
    private static func huffmanDecode(
        reader: inout JPEGBitReader,
        table: JPEGHuffmanTable
    ) throws -> Int {
        var length = 1
        var code = try reader.nextBit()
        while length <= 16 {
            if table.maxcode[length] >= 0, code <= table.maxcode[length] {
                let index = table.valptr[length] + (code - table.mincode[length])
                guard index >= 0, index < table.huffval.count else {
                    throw AssetError.malformedImageData
                }
                return Int(table.huffval[index])
            }
            length += 1
            guard length <= 16 else { break }
            code = try (code << 1) | (reader.nextBit())
        }
        throw AssetError.malformedImageData
    }

    /// Builds a canonical Huffman decode table from its wire-format
    /// `BITS`/`HUFFVAL` (ITU-T.81 Annex C.2 `Generate_size_table`/
    /// `Generate_code_table`, folded together, since only decode -- never
    /// re-encode -- is needed here).
    static func buildHuffmanTable(
        counts: [Int],
        values: [UInt8]
    ) throws -> JPEGHuffmanTable {
        guard counts.count == 16 else { throw AssetError.malformedImageData }
        let totalSymbols = counts.reduce(0, +)
        guard totalSymbols == values.count, totalSymbols > 0, totalSymbols <= 256 else {
            throw AssetError.malformedImageData
        }

        var mincode = [Int](repeating: -1, count: 17)
        var maxcode = [Int](repeating: -1, count: 17)
        var valptr = [Int](repeating: -1, count: 17)

        var code = 0
        var symbolIndex = 0
        for length in 1 ... 16 {
            let count = counts[length - 1]
            guard count >= 0 else { throw AssetError.malformedImageData }
            if count == 0 {
                maxcode[length] = -1
            } else {
                valptr[length] = symbolIndex
                mincode[length] = code
                code += count
                symbolIndex += count
                maxcode[length] = code - 1
                // Over-subscription check: this length cannot need more
                // distinct code values than `length` bits can represent
                // (`2^length` total). A `BITS` table that assigns more
                // codes at some length than the canonical Huffman
                // construction can actually support is malformed --
                // never merely "unlikely", since a correctly-encoded
                // JPEG can never produce one.
                guard maxcode[length] <= (1 << length) - 1 else {
                    throw AssetError.malformedImageData
                }
            }
            code <<= 1
        }

        return JPEGHuffmanTable(mincode: mincode, maxcode: maxcode, valptr: valptr, huffval: values)
    }
}

/// Reads individual bits, MSB-first, from a JPEG entropy-coded byte range,
/// transparently destuffing `FF 00` -> literal `FF` and explicitly
/// handling restart-marker resynchronization -- callers must call
/// ``consumeRestartMarker(expected:)`` at exactly the expected point
/// (never encountering `FFD0`-`FFD7` organically mid-``nextBit()``, which
/// is treated as a premature/malformed stream).
struct JPEGBitReader {
    private let data: Data
    private var byteIndex: Int
    private let end: Int
    private var bitBuffer: UInt8 = 0
    private var bitCount: Int = 0

    init(data: Data, start: Int, end: Int) {
        self.data = data
        byteIndex = start
        self.end = end
    }

    mutating func nextBit() throws -> Int {
        if bitCount == 0 {
            try fillByte()
        }
        bitCount -= 1
        return Int((bitBuffer >> bitCount) & 1)
    }

    private mutating func fillByte() throws {
        guard byteIndex < end else { throw AssetError.malformedImageData }
        let byte = data[byteIndex]
        byteIndex += 1
        if byte == 0xFF {
            guard byteIndex < end else { throw AssetError.malformedImageData }
            let next = data[byteIndex]
            if next == 0x00 {
                // Byte-stuffed literal 0xFF: consume the stuffing byte,
                // the data byte itself is the literal 0xFF already read.
                byteIndex += 1
            } else {
                // A real marker (including a restart marker) reached
                // while still expecting more entropy-coded bits for the
                // current block/MCU: the stream is incomplete/malformed.
                // Restart markers are only ever valid at an
                // already-byte-aligned MCU boundary, consumed explicitly
                // via `consumeRestartMarker(expected:)` -- never reached
                // from inside `nextBit()`'s own byte refill.
                throw AssetError.malformedImageData
            }
        }
        bitBuffer = byte
        bitCount = 8
    }

    /// Discards any unread bits of the current partially-consumed byte
    /// (byte-aligning), for the restart-marker boundary immediately after.
    private mutating func byteAlign() {
        bitCount = 0
        bitBuffer = 0
    }

    mutating func consumeRestartMarker(expected: UInt8) throws {
        byteAlign()
        guard byteIndex + 1 < end, data[byteIndex] == 0xFF, data[byteIndex + 1] == expected else {
            throw AssetError.malformedImageData
        }
        byteIndex += 2
    }

    /// Called once every planned MCU has been decoded: verifies that
    /// (a) if the final byte's bits were not entirely consumed, the
    /// unconsumed low bits are the standard all-1s padding, and
    /// (b) the reader's byte position lands exactly on `end` -- neither
    /// stopping early (leftover, un-decoded real bytes = trailing
    /// garbage before the next marker) nor having somehow read past it
    /// (`fillByte()` itself already prevents this via its own bounds
    /// check).
    mutating func requireExhaustedAtEnd() throws {
        if bitCount > 0 {
            let padding = bitBuffer & ((1 << bitCount) - 1)
            let expectedPadding: UInt8 = (1 << bitCount) - 1
            guard padding == expectedPadding else { throw AssetError.malformedImageData }
        }
        guard byteIndex == end else { throw AssetError.malformedImageData }
    }
}
