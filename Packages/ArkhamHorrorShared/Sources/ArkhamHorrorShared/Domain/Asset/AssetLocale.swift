/// A locale the asset pipeline can request a localized card image for.
///
/// This mirrors the web client's fixed locale-to-asset-root mapping exactly;
/// it intentionally does not attempt to derive a root from an arbitrary
/// `Locale` or BCP-47 tag, since only these five roots exist on the CDN.
enum AssetLocale: String, CaseIterable, Sendable, Equatable, Hashable {
    case english = "en"
    case italian = "it"
    case french = "fr"
    case spanish = "es"
    case korean = "ko"
    case chinese = "zh"

    /// The web client's asset path root for this locale (e.g. `it` maps to the
    /// `ita` directory on the CDN). `nil` for ``english``, which has no
    /// separate localized root — English art is the base `cards/` path.
    var pathRoot: String? {
        switch self {
        case .english: nil
        case .italian: "ita"
        case .french: "fr"
        case .spanish: "es"
        case .korean: "ko"
        case .chinese: "zh"
        }
    }

    /// The key used to look up this locale's compact digest resource and its
    /// vendored raw fixture (see `Resources/AssetDigests/PROVENANCE.md`).
    var digestResourceName: String? {
        self == .english ? nil : rawValue
    }
}
