import CoreGraphics
import Foundation
import ImageIO

/// Decodes already-validated, cached asset bytes into a `CGImage`.
///
/// Uses ImageIO, which is available identically across iOS, macOS, tvOS,
/// and visionOS, rather than a platform-specific `UIImage`/`NSImage` type —
/// this keeps the presentation seam platform-neutral. This is a full
/// platform decode and is only ever reached after
/// ``AssetImageValidator/validate(data:declaredContentType:expectedFormat:limits:)``
/// has already confirmed a matching signature, a complete codec structure
/// (for PNG/JPEG; see `AssetImageValidator+PNGStructure.swift` and
/// `AssetImageValidator+JPEGStructure.swift`), and safe dimensions, so it
/// is never invoked on unvalidated, arbitrary bytes.
///
/// `CGImageSourceCreateImageAtIndex` alone is not a trustworthy
/// completeness gate: it is a lazy, best-effort decoder that can still
/// return *a* `CGImage` for data ImageIO only partially understood. This
/// additionally checks ImageIO's own reported completeness status and
/// forces every pixel to actually be realized (by drawing into a bitmap
/// context sized to the image's own dimensions) before returning,
/// rather than merely proving that image creation itself did not return
/// `nil`. This is defense-in-depth alongside — not a replacement for —
/// the structural validators, which are this pipeline's primary,
/// deterministic truncation/corruption gate.
enum AssetImageDecoder {
    static func decode(_ payload: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(payload as CFData, nil) else {
            throw AssetError.malformedImageData
        }
        // Exactly one coded image, never an animation/frame sequence (an
        // animated PNG's `acTL`/`fcTL`/`fdAT` chunks, a multi-frame GIF
        // masquerading behind a renamed extension, or an AVIF image
        // *sequence*): this pipeline validates, decodes, and caches a
        // single still image only, and silently accepting a multi-frame
        // source here would decode and publish only its first frame while
        // never having validated — or even looked at — the rest.
        guard CGImageSourceGetCount(source) == 1 else {
            throw AssetError.malformedImageData
        }
        guard CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else {
            throw AssetError.malformedImageData
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AssetError.malformedImageData
        }
        try forceEagerPixelDecode(image)
        return image
    }

    /// Forces ImageIO to fully realize `image`'s pixel data by drawing it
    /// into a freshly allocated bitmap context sized to its own
    /// dimensions, rather than trusting that a non-nil `CGImage` already
    /// means every compressed byte was successfully decoded — a lazy
    /// decoder can defer real pixel-data realization until first access.
    ///
    /// Only ever called after ``AssetImageValidator`` has already bounded
    /// `image`'s dimensions to the configured limits, so this allocation
    /// size is itself already bounded.
    private static func forceEagerPixelDecode(_ image: CGImage) throws {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw AssetError.malformedImageData }
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
            throw AssetError.malformedImageData
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
