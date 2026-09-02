import CryptoKit
import Foundation

/// A single shared SHA-256-over-payload-bytes helper, used both to persist
/// ``AssetCacheMetadata/payloadSHA256Hex`` on write and to re-verify it on
/// every disk cache read.
enum AssetPayloadHasher {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
