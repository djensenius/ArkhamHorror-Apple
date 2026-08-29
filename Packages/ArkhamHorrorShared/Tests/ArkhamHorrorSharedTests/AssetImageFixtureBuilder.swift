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
}
