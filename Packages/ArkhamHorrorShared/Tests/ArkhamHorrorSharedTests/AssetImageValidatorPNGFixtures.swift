@testable import ArkhamHorrorShared
import Foundation
import ImageIO
import Testing

/// Genuine, ImageIO-encoded PNG fixture builders shared by
/// `AssetImageValidatorPNGPaletteTests.swift` and
/// `AssetImageValidatorPNGTransparencyTests.swift` -- split out purely to
/// stay under SwiftLint's `file_length`, since both files' own `PLTE`/
/// `tRNS` coverage needs the exact same underlying grayscale/truecolor
/// fixtures. Every fixture here is produced by an actual `CGContext` fill
/// encoded via `CGImageDestinationCreateWithData`, never a hand-assembled
/// byte array, so every mutation test that splices bytes into one starts
/// from something ImageIO itself would otherwise happily decode.
extension AssetImageValidatorTests {
    /// A genuine, ImageIO-encoded pure-grayscale (no alpha, `colorType ==
    /// 0`) PNG, built the same way ``AssetImageFixtureBuilder``'s own
    /// RGBA fixtures are (a filled `CGContext`, encoded via
    /// `CGImageDestinationCreateWithData`) but with `CGColorSpaceCreateDeviceGray()`
    /// and no alpha channel, which ImageIO's PNG encoder emits as
    /// `colorType == 0`.
    func grayscaleFixture(
        width: Int, height: Int
    ) throws -> (Data, AssetImageValidator.PNGColorInfo) {
        let data = try AssetImageValidatorPNGPaletteTests.renderGray(
            width: width, height: height, alpha: false
        )
        return try (data, AssetImageValidator.parsePNGColorInfo(data))
    }

    /// The grayscale+alpha (`colorType == 4`) counterpart of
    /// ``grayscaleFixture(width:height:)``.
    func grayscaleAlphaFixture(
        width: Int, height: Int
    ) throws -> (Data, AssetImageValidator.PNGColorInfo) {
        let data = try AssetImageValidatorPNGPaletteTests.renderGray(
            width: width, height: height, alpha: true
        )
        return try (data, AssetImageValidator.parsePNGColorInfo(data))
    }

    /// A genuine, ImageIO-encoded truecolor-without-alpha (`colorType ==
    /// 2`) PNG -- the color type for which both `PLTE` and `tRNS` are
    /// optional, neither required by the other, unlike indexed color
    /// (type 3, where `PLTE` is mandatory) or the fully-opaque-alpha
    /// types (4/6, where `tRNS` is forbidden outright).
    func truecolorFixture(
        width: Int, height: Int
    ) throws -> (Data, AssetImageValidator.PNGColorInfo) {
        let data = try AssetImageValidatorPNGPaletteTests.renderRGB(
            width: width, height: height, alpha: false
        )
        return try (data, AssetImageValidator.parsePNGColorInfo(data))
    }
}

/// A free-standing namespace for the grayscale/truecolor PNG renderers
/// used above -- kept outside the `AssetImageValidatorTests` extension
/// purely so its `CGContext`/`CGImageDestination` plumbing doesn't need
/// to live inline in every call site.
enum AssetImageValidatorPNGPaletteTests {
    static func renderGray(width: Int, height: Int, alpha: Bool) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = alpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.none.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw AssetError.malformedImageData
        }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else {
            throw AssetError.malformedImageData
        }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, "public.png" as CFString, 1, nil
            )
        else {
            throw AssetError.malformedImageData
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AssetError.malformedImageData
        }
        return data as Data
    }

    /// The device-RGB counterpart of ``renderGray(width:height:alpha:)``,
    /// used to produce a genuine truecolor (`colorType == 2`, when
    /// `alpha` is `false`) PNG fixture.
    static func renderRGB(width: Int, height: Int, alpha: Bool) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = alpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw AssetError.malformedImageData
        }
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else {
            throw AssetError.malformedImageData
        }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, "public.png" as CFString, 1, nil
            )
        else {
            throw AssetError.malformedImageData
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AssetError.malformedImageData
        }
        return data as Data
    }
}
