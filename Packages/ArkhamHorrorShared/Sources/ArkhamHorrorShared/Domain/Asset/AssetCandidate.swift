import Foundation

/// A single, fully-resolved path in a fallback chain that ``AssetLocator``
/// produces for an ``AssetKey``.
///
/// The initializer is `fileprivate`; the only way to construct one from
/// outside this file is ``AssetCandidateFactory/make(segments:localeRoot:format:)``,
/// which is `internal` (module-wide), not restricted to ``AssetLocator``
/// specifically. In practice only ``AssetLocator`` calls it today, from
/// already-validated ``AssetIdentifier`` segments, so callers can never
/// construct a request for an arbitrary relative path — but that guarantee
/// comes from this module never exposing an unvalidated-segments entry
/// point publicly, not from Swift access control naming a single caller.
struct AssetCandidate: Sendable, Equatable, Hashable {
    /// Path segments relative to the CDN's `img/arkham/` root, in order
    /// (e.g. `["cards", "01001.avif"]`). Never contains `/`, and never
    /// contains `..` or an empty segment: each was built from a validated
    /// ``AssetIdentifier`` or a fixed literal.
    let segments: [String]
    /// The locale root folder to insert directly after `img/arkham/`, or
    /// `nil` for the base (English/non-localized) path.
    let localeRoot: String?
    let format: AssetFormat

    fileprivate init(segments: [String], localeRoot: String?, format: AssetFormat) {
        precondition(!segments.isEmpty, "An asset candidate must have at least one segment")
        precondition(
            segments.allSatisfy { !$0.isEmpty },
            "Asset candidate segments must not be empty"
        )
        self.segments = segments
        self.localeRoot = localeRoot
        self.format = format
    }

    /// A stable, order-preserving string representation of this candidate,
    /// used only as a component folded into the disk cache key — never sent
    /// over the network directly (``url(base:)`` builds the request URL).
    var canonicalPathComponent: String {
        let root = localeRoot.map { "\($0)/" } ?? ""
        return "img/arkham/" + root + segments.joined(separator: "/")
    }

    /// Builds the full request URL against `base`, safely percent-encoding
    /// every segment via `appendingPathComponent` rather than string
    /// concatenation.
    func url(base: AssetSourceNamespace) -> URL {
        var url = base.canonicalOrigin
        for pathSegment in base.basePath.split(separator: "/") {
            url = url.appendingPathComponent(String(pathSegment))
        }
        url = url.appendingPathComponent("img").appendingPathComponent("arkham")
        if let localeRoot {
            url = url.appendingPathComponent(localeRoot)
        }
        for segment in segments {
            url = url.appendingPathComponent(segment)
        }
        return url
    }
}

// MARK: - Construction (internal to this module; not a public API)

/// Builds ``AssetCandidate`` values from already-validated segments.
///
/// This is `internal`, so any file within `ArkhamHorrorShared` can call it —
/// not exclusively ``AssetLocator`` — but no target outside this package
/// can, since nothing here is `public`. The actual guarantee this module
/// upholds is: no caller, anywhere, can build an `AssetCandidate` from an
/// arbitrary/unvalidated relative path string; every call site that exists
/// today (``AssetLocator``) only ever passes segments that already came from
/// a validated ``AssetIdentifier`` or a fixed literal.
enum AssetCandidateFactory {
    static func make(
        segments: [String],
        localeRoot: String?,
        format: AssetFormat
    ) -> AssetCandidate {
        AssetCandidate(segments: segments, localeRoot: localeRoot, format: format)
    }
}
