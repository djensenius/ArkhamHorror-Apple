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
/// has already confirmed a matching signature and safe dimensions, so it is
/// never invoked on unvalidated, arbitrary bytes.
enum AssetImageDecoder {
    static func decode(_ payload: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw AssetError.malformedImageData
        }
        return image
    }
}
