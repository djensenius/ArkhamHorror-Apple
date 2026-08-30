@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for ``AssetImageValidator``'s AVIF item-extent coverage proof
/// (`AssetImageValidator+AVIFItemExtents.swift`'s
/// `validateAVIFItemExtentCoverage`), which closes a gap `CGImageSourceCopyPropertiesAtIndex`
/// alone cannot: that call only ever looks at the bytes an item's own
/// `iloc` extents reference, so it has no way to notice extra bytes an
/// attacker appends *inside* an `mdat` box's own declared span, beyond
/// every item's referenced extent -- whether that box declares an
/// explicit size that happens to include the extra bytes, or a
/// size-zero/size-one-with-extended-size box that (by ISO-BMFF
/// definition) silently extends to absorb whatever remains until the end
/// of its parent range.
struct AssetImageValidatorAVIFItemExtentTests {
    private let limits = AssetCacheLimits(
        maxEncodedBytes: 20 * 1024 * 1024,
        maxDimension: 8192,
        maxPixelCount: 32_000_000,
        memoryBudgetBytes: 1024,
        diskBudgetBytes: 1024
    )

    // MARK: - Byte-level box helpers (mirroring AssetImageValidator+AVIF.swift's own reader)

    private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    private func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0 ..< 8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }

    private func writeUInt64BE(_ value: UInt64, into data: inout Data, at offset: Int) {
        for index in 0 ..< 8 {
            data[offset + index] = UInt8((value >> (8 * (7 - index))) & 0xFF)
        }
    }

    /// Locates the real, ImageIO-produced `mdat` top-level box (as an
    /// extended, 64-bit-size `size32 == 1` box, which is exactly the form
    /// `CGImageDestination` emits) within `data`, returning its header
    /// start offset.
    private func findMdatHeaderOffset(in data: Data) throws -> Int {
        var offset = data.startIndex
        while offset + 8 <= data.endIndex {
            let size32 = readUInt32BE(data, at: offset)
            let type = String(bytes: data[(offset + 4) ..< (offset + 8)], encoding: .utf8) ?? ""
            let boxSize: Int = if size32 == 1 {
                Int(readUInt64BE(data, at: offset + 8))
            } else if size32 == 0 {
                data.endIndex - offset
            } else {
                Int(size32)
            }
            if type == "mdat" {
                return offset
            }
            offset += boxSize
        }
        throw TestError.mdatNotFound
    }

    private enum TestError: Error {
        case mdatNotFound
    }

    @Test(
        """
        Trailing bytes appended after a real AVIF's coded item, but folded into an mdat box whose \
        size32 field is set to 0 (extends-to-EOF), are rejected rather than silently absorbed
        """
    )
    func sizeZeroMdatTrailingBytesRejected() throws {
        var data = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
        let mdatOffset = try findMdatHeaderOffset(in: data)
        // Rewrite this box's size32 field from `1` (extended 64-bit size)
        // to `0` ("extends to the end of the parent range"), dropping the
        // now-unused 8-byte extended-size field's meaning entirely (it is
        // simply leftover payload bytes once size32 == 0), then append
        // fresh trailing bytes -- unreferenced by any `iloc` extent -- so
        // the whole appended tail is absorbed into this box purely by
        // virtue of size32 == 0's own semantics.
        data.replaceSubrange(
            mdatOffset ..< mdatOffset + 4,
            with: withUnsafeBytes(of: UInt32(0).bigEndian, Array.init)
        )
        data.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: data,
                declaredContentType: nil,
                expectedFormat: .avif,
                limits: limits
            )
        }
    }

    @Test(
        """
        Trailing bytes appended after a real AVIF's coded item, with the mdat box's own explicit \
        extended size field enlarged to still declare a single well-formed box spanning them, are \
        rejected because no iloc extent references the appended tail
        """
    )
    func explicitlyEnlargedMdatTrailingBytesRejected() throws {
        var data = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
        let mdatOffset = try findMdatHeaderOffset(in: data)
        let originalSize = readUInt64BE(data, at: mdatOffset + 8)
        let appended: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        data.append(contentsOf: appended)
        // Enlarge the box's own declared (extended) size by exactly the
        // appended byte count, so the top-level box walk still sees one
        // well-formed box reaching precisely to the new end of file --
        // this is deliberately *not* the size32 == 0 case, proving the
        // coverage check catches unreferenced trailing bytes regardless
        // of which ISO-BMFF mechanism a box uses to claim them.
        writeUInt64BE(originalSize + UInt64(appended.count), into: &data, at: mdatOffset + 8)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: data,
                declaredContentType: nil,
                expectedFormat: .avif,
                limits: limits
            )
        }
    }

    @Test(
        "Untampered real AVIF fixture's own item-extent coverage is exact and validates"
    )
    func untamperedRealAVIFCoverageValidates() throws {
        let data = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
        let metadata = try AssetImageValidator.validate(
            data: data,
            declaredContentType: nil,
            expectedFormat: .avif,
            limits: limits
        )
        #expect(metadata.width == 4)
        #expect(metadata.height == 4)
    }

    @Test(
        "Deleting one byte from a real AVIF's mdat payload (short coverage) is rejected"
    )
    func truncatedMdatPayloadRejected() throws {
        var data = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
        let mdatOffset = try findMdatHeaderOffset(in: data)
        let originalSize = readUInt64BE(data, at: mdatOffset + 8)
        // Remove one byte from the very end of the file (the tail of the
        // coded payload itself) without adjusting the box's own declared
        // size: the iloc extent still claims the original (now
        // impossible) length, which the coverage check must reject as a
        // mismatch rather than silently clamping to whatever bytes remain.
        data.removeLast()
        #expect(readUInt64BE(data, at: mdatOffset + 8) == originalSize)

        #expect(throws: AssetError.malformedImageData) {
            _ = try AssetImageValidator.validate(
                data: data,
                declaredContentType: nil,
                expectedFormat: .avif,
                limits: limits
            )
        }
    }
}
