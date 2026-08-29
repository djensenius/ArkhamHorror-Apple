@testable import ArkhamHorrorShared
import CoreGraphics
import Foundation
import ImageIO

/// Builds small, fully synthetic image byte fixtures for
/// ``AssetImageValidatorTests`` and decoder tests.
///
/// PNG and JPEG fixtures are real, decodable images generated at test time
/// via ImageIO — never an embedded or fetched binary. AVIF fixtures are
/// hand-assembled minimal ISO-BMFF box trees containing only the boxes
/// ``AssetImageValidator`` actually parses (`ftyp`, `meta`, `iprp`, `ipco`,
/// `ispe`); they are not real AV1-coded pictures (this package has no way
/// to encode one, and does not need to: the validator never attempts a full
/// decode), so they are useful for validator tests but not decode tests.
enum AssetImageFixtureBuilder {
    // MARK: - Real, decodable PNG/JPEG

    static func validPNG(width: Int = 4, height: Int = 4) -> Data {
        render(width: width, height: height, utType: "public.png")
    }

    static func validJPEG(width: Int = 4, height: Int = 4) -> Data {
        render(width: width, height: height, utType: "public.jpeg")
    }

    private static func render(width: Int, height: Int, utType: String) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            preconditionFailure("Fixture bitmap context creation must succeed for small test sizes")
        }
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else {
            preconditionFailure("Fixture image creation must succeed for a filled bitmap context")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, utType as CFString, 1, nil)
        else {
            preconditionFailure("Fixture image destination creation must succeed for '\(utType)'")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            preconditionFailure("Fixture image finalization must succeed for '\(utType)'")
        }
        return data as Data
    }

    // MARK: - Hand-assembled minimal AVIF (ISO-BMFF) shell

    /// Builds a byte sequence with a valid `ftyp`/`meta`/`iprp`/`ipco`/`ispe`
    /// box structure declaring `width`×`height`, matching exactly what
    /// ``AssetImageValidator``'s AVIF branch parses. No `mdat` (coded
    /// picture data) is included since the validator never reads it.
    static func syntheticAVIF(width: Int, height: Int, brand: String = "avif") -> Data {
        func box(_ type: String, _ payload: Data) -> Data {
            var result = Data()
            let size = UInt32(8 + payload.count)
            result.append(contentsOf: withUnsafeBytes(of: size.bigEndian, Array.init))
            result.append(contentsOf: Array(type.utf8))
            result.append(payload)
            return result
        }

        var ftypPayload = Data(Array(brand.utf8))
        ftypPayload.append(contentsOf: [0, 0, 0, 0]) // minor version
        ftypPayload.append(contentsOf: Array(brand.utf8)) // one compatible brand: itself
        ftypPayload.append(contentsOf: Array("mif1".utf8))
        let ftyp = box("ftyp", ftypPayload)

        var ispePayload = Data([0, 0, 0, 0]) // version/flags
        ispePayload.append(contentsOf: withUnsafeBytes(of: UInt32(width).bigEndian, Array.init))
        ispePayload.append(contentsOf: withUnsafeBytes(of: UInt32(height).bigEndian, Array.init))
        let ispe = box("ispe", ispePayload)
        let ipco = box("ipco", ispe)
        let iprp = box("iprp", ipco)
        var metaPayload = Data([0, 0, 0, 0]) // meta's own version/flags
        metaPayload.append(iprp)
        let meta = box("meta", metaPayload)

        return ftyp + meta
    }

    /// A truncated AVIF: a well-formed `ftyp` declaring the right brand, but
    /// no `meta` box at all.
    static func avifMissingMeta(brand: String = "avif") -> Data {
        func box(_ type: String, _ payload: Data) -> Data {
            var result = Data()
            let size = UInt32(8 + payload.count)
            result.append(contentsOf: withUnsafeBytes(of: size.bigEndian, Array.init))
            result.append(contentsOf: Array(type.utf8))
            result.append(payload)
            return result
        }
        var ftypPayload = Data(Array(brand.utf8))
        ftypPayload.append(contentsOf: [0, 0, 0, 0])
        ftypPayload.append(contentsOf: Array(brand.utf8))
        return box("ftyp", ftypPayload)
    }

    /// An AVIF whose `ispe` box declares only enough payload for its
    /// 4-byte version/flags field plus a 4-byte width — no room at all for
    /// a height field — followed immediately, still inside `ipco`'s own
    /// payload (not as a legitimate sibling box), by 4 bytes that look like
    /// a plausible height value. A parser that bounds-checks reads only
    /// against the whole buffer (rather than against the `ispe` box's own
    /// declared payload range) would read those trailing bytes as if they
    /// were the box's height field and report bogus-but-plausible
    /// dimensions instead of rejecting the box as malformed.
    static func syntheticAVIFTruncatedISPE(width: Int, brand: String = "avif") -> Data {
        func box(_ type: String, _ payload: Data) -> Data {
            var result = Data()
            let size = UInt32(8 + payload.count)
            result.append(contentsOf: withUnsafeBytes(of: size.bigEndian, Array.init))
            result.append(contentsOf: Array(type.utf8))
            result.append(payload)
            return result
        }

        var ftypPayload = Data(Array(brand.utf8))
        ftypPayload.append(contentsOf: [0, 0, 0, 0])
        ftypPayload.append(contentsOf: Array(brand.utf8))
        ftypPayload.append(contentsOf: Array("mif1".utf8))
        let ftyp = box("ftyp", ftypPayload)

        var truncatedISPEPayload = Data([0, 0, 0, 0]) // version/flags
        truncatedISPEPayload.append(
            contentsOf: withUnsafeBytes(of: UInt32(width).bigEndian, Array.init)
        )
        let truncatedISPE = box("ispe", truncatedISPEPayload)
        let bogusTrailingHeightBytes = Data(
            withUnsafeBytes(of: UInt32(9999).bigEndian, Array.init)
        )
        let ipco = box("ipco", truncatedISPE + bogusTrailingHeightBytes)
        let iprp = box("iprp", ipco)
        var metaPayload = Data([0, 0, 0, 0])
        metaPayload.append(iprp)
        let meta = box("meta", metaPayload)

        return ftyp + meta
    }

    /// An AVIF whose `ipco` contains one child box using the 64-bit
    /// extended-size form (`size32 == 1`), but whose own declared box size
    /// leaves no room at all for the required 8-byte extended-size field
    /// after the base 8-byte size/type header — only the header itself
    /// fits inside `ipco`'s declared range. Immediately following it,
    /// still inside `iprp`'s own payload (not as a legitimate part of the
    /// truncated child box), are 8 bytes that look like a small, plausible
    /// extended size. A parser that bounds-checks the extended-size read
    /// only against the whole buffer (rather than against the enclosing
    /// range it is walking) would read those trailing bytes as if they
    /// belonged to the truncated box instead of rejecting it as malformed.
    static func syntheticAVIFExtendedSizeBoxTruncated(brand: String = "avif") -> Data {
        func box(_ type: String, _ payload: Data) -> Data {
            var result = Data()
            let size = UInt32(8 + payload.count)
            result.append(contentsOf: withUnsafeBytes(of: size.bigEndian, Array.init))
            result.append(contentsOf: Array(type.utf8))
            result.append(payload)
            return result
        }

        var ftypPayload = Data(Array(brand.utf8))
        ftypPayload.append(contentsOf: [0, 0, 0, 0])
        ftypPayload.append(contentsOf: Array(brand.utf8))
        ftypPayload.append(contentsOf: Array("mif1".utf8))
        let ftyp = box("ftyp", ftypPayload)

        // A child box's base header only: size32 == 1 (4 bytes) + type
        // "ispe" (4 bytes) = 8 bytes total, with no extended-size field.
        var truncatedExtendedSizeBox = Data(
            withUnsafeBytes(of: UInt32(1).bigEndian, Array.init)
        )
        truncatedExtendedSizeBox.append(contentsOf: Array("ispe".utf8))
        let ipco = box("ipco", truncatedExtendedSizeBox)
        let bogusTrailingSize64Bytes = Data(
            withUnsafeBytes(of: UInt64(16).bigEndian, Array.init)
        )
        let iprp = box("iprp", ipco + bogusTrailingSize64Bytes)
        var metaPayload = Data([0, 0, 0, 0])
        metaPayload.append(iprp)
        let meta = box("meta", metaPayload)

        return ftyp + meta
    }
}
