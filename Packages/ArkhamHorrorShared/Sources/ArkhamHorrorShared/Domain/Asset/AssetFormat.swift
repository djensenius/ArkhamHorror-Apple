/// The encoded image format a candidate path resolves to.
///
/// This drives the magic-byte signature ``AssetImageValidator`` requires on
/// the response body and the MIME type it is checked against; a mismatch
/// between the two is always a typed failure, never a silent fallback. The
/// asset transport does not send a request `Accept` header (candidates are
/// already resolved to an exact, format-specific path by ``AssetLocator``,
/// so there is nothing for content negotiation to select between).
enum AssetFormat: String, Sendable, Equatable, Hashable {
    case avif
    case jpeg
    case png

    /// The canonical MIME type declared by the CDN for this format.
    var mimeType: String {
        switch self {
        case .avif: "image/avif"
        case .jpeg: "image/jpeg"
        case .png: "image/png"
        }
    }

    /// The file extension used on disk for this format's canonical path.
    var pathExtension: String {
        switch self {
        case .avif: "avif"
        case .jpeg: "jpg"
        case .png: "png"
        }
    }
}
