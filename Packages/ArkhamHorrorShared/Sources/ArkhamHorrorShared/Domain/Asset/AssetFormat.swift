/// The encoded image format a candidate path resolves to.
///
/// This drives both the declared `Accept` header sent by the transport and
/// the magic-byte signature ``AssetImageValidator`` requires on the response
/// body; a mismatch between the two is always a typed failure, never a
/// silent fallback.
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
