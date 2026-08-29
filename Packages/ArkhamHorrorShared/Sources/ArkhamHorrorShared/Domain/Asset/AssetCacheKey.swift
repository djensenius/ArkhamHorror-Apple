import CryptoKit
import Foundation

/// A stable, opaque disk filename derived from a SHA-256 hash over a
/// versioned canonical string — never from raw server path segments, so a
/// hostile or unusual identifier can never influence the on-disk layout
/// beyond its own cache entry.
struct AssetCacheKey: Sendable, Equatable, Hashable {
    /// The hex-encoded SHA-256 digest. Safe to use directly as a filename
    /// component on every supported platform (lowercase hex only).
    let digestHex: String

    /// Bumped whenever the canonical key composition changes, so upgrading
    /// this package never silently reinterprets an old cache entry's key as
    /// if it meant something else; entries keyed under a prior version are
    /// simply orphaned and reclaimed by normal quota eviction.
    private static let version = "1"

    /// Derives the key from `key`'s source namespace and locale, plus the
    /// exact ordered candidate sequence ``AssetLocator`` resolved for it.
    ///
    /// `key.category` is deliberately not folded in directly: every
    /// category maps to its own literal path segment prefix (e.g.
    /// `"cards"`, `"chaos-tokens"`), so it is already fully represented by
    /// each candidate's ``AssetCandidate/canonicalPathComponent``. This
    /// avoids hashing `String(describing:)` of an enum, which is not a
    /// stable serialization format and could silently change across Swift
    /// versions.
    ///
    /// Folding in the full candidate sequence (not just the abstract key)
    /// means that if a locale digest update changes which candidates would
    /// be tried — or in what order — for the same logical request, that is
    /// treated as a distinct cache entry rather than risking a stale
    /// candidate's bytes being served under a key that now means something
    /// else.
    init(for key: AssetKey, candidates: [AssetCandidate]) {
        var canonical = Self.version
        canonical += "\u{1}" + key.source.canonicalIdentity
        canonical += "\u{1}" + key.locale.rawValue
        for candidate in candidates {
            canonical += "\u{1}" + candidate.canonicalPathComponent
            canonical += "\u{1}" + candidate.format.rawValue
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        digestHex = digest.map { String(format: "%02x", $0) }.joined()
    }
}
