import Foundation

/// Loads the compact per-locale digest resources bundled with this package
/// (see `Resources/AssetDigests/PROVENANCE.md`) and answers
/// ``LocalizedDigestLookup`` queries against them.
///
/// Every locale's identifier list is validated and decoded eagerly, once,
/// at construction — never lazily on first use — so a genuinely broken
/// resource (missing from the bundle, unreadable, or not valid JSON) is
/// surfaced as soon as this type is composed, as a typed, catchable
/// ``AssetError/configurationFailure(_:)``, rather than trapping the
/// process the first time some caller happens to touch that locale. A
/// locale that legitimately ships an empty digest (`ko`, which has no
/// localized card art yet) still loads successfully to `[]`: only an
/// actual load/parse failure is ``AssetError/configurationFailure(_:)``,
/// so the two conditions are never conflated. Once constructed, every
/// query below is a plain, non-throwing, lock-free dictionary lookup
/// against this already-validated state.
final class BundledLocalizedDigestProvider: LocalizedDigestLookup, @unchecked Sendable {
    /// Shared instance backing the default ``AssetLocator``.
    ///
    /// `AssetLocator.candidates(for:digest:)` and
    /// ``AssetCacheService/init(memoryCache:diskCache:transport:digest:limits:)``
    /// both use this as a default parameter value, and Swift does not
    /// permit a throwing expression as a default argument — so this
    /// property itself cannot be throwing. It resolves the throwing,
    /// eagerly-validating initializer exactly once via `Result`, retains
    /// whatever it produced (success or failure) in ``configurationError``
    /// for observability, and falls back to an explicitly-empty instance
    /// only in the failure case (an unrecoverable packaging regression in
    /// this package's own shipped resources, which every other test in
    /// this suite confirms does not occur for the real bundle).
    static let shared: BundledLocalizedDigestProvider = switch Result(
        catching: { try BundledLocalizedDigestProvider(bundle: .module) }
    ) {
    case let .success(provider):
        provider
    case let .failure(error):
        BundledLocalizedDigestProvider(
            configurationError: BundledLocalizedDigestProvider.asAssetError(error)
        )
    }

    /// Non-`nil` only for the extraordinarily unlikely fallback branch of
    /// ``shared``, where the real bundle's own resources failed to load —
    /// exposed so that failure remains observable (loggable/reportable)
    /// rather than silently indistinguishable from a legitimately-empty
    /// locale.
    let configurationError: AssetError?

    private let orderedCache: [AssetLocale: [String]]
    private let lookupCache: [AssetLocale: Set<String>]

    /// The throwing, eagerly-validating composition-time initializer:
    /// every locale named by ``AssetLocale/digestResourceName`` is loaded
    /// and decoded right now, synchronously, and any failure throws
    /// ``AssetError/configurationFailure(_:)`` immediately rather than
    /// deferring the failure to whichever call happens to touch that
    /// locale first.
    init(bundle: Bundle = .module) throws {
        var ordered: [AssetLocale: [String]] = [:]
        var lookup: [AssetLocale: Set<String>] = [:]
        for locale in AssetLocale.allCases {
            guard let resourceName = locale.digestResourceName else { continue }
            let identifiers = try Self.load(resourceName: resourceName, bundle: bundle)
            ordered[locale] = identifiers
            lookup[locale] = Set(identifiers)
        }
        orderedCache = ordered
        lookupCache = lookup
        configurationError = nil
    }

    /// Constructs an instance that answers "no localized art" for every
    /// locale, recording `configurationError` for observability. Never
    /// used by the throwing initializer above; only by ``shared``'s
    /// fallback branch.
    private init(configurationError: AssetError) {
        orderedCache = [:]
        lookupCache = [:]
        self.configurationError = configurationError
    }

    func hasLocalizedArt(_ identifier: AssetIdentifier, locale: AssetLocale) -> Bool {
        lookupCache[locale]?.contains(identifier.rawValue) ?? false
    }

    /// The full loaded identifier set for `locale`, or `nil` for
    /// ``AssetLocale/english`` (which has no digest resource).
    func identifierSet(for locale: AssetLocale) -> Set<String>? {
        lookupCache[locale]
    }

    /// The full loaded identifier list for `locale`, in the exact order
    /// stored in the shipped resource, or `nil` for
    /// ``AssetLocale/english`` (which has no digest resource). Not
    /// `private` so `LocalizedDigestCompactorDriftTests` can compare it
    /// directly, order-sensitively, against a freshly recompacted raw
    /// fixture — catching ordering drift or duplicate entries that an
    /// unordered `Set`-only comparison could never detect — without
    /// needing to locate and re-decode this package's resource bundle
    /// itself.
    func orderedIdentifiers(for locale: AssetLocale) -> [String]? {
        orderedCache[locale]
    }

    /// Loads `resourceName.json` from `bundle`, preserving the shipped
    /// array's exact order (never collapsed to a `Set` at this layer, so
    /// callers that need order-sensitive comparisons — e.g. drift tests —
    /// can still get it).
    ///
    /// The subdirectory is `"Resources/AssetDigests"`, not just
    /// `"AssetDigests"`: `Package.swift` declares this target's resources as
    /// `.copy("Resources")`, which (unlike `.process`) preserves the copied
    /// directory's own name inside the resource bundle, so the digest files
    /// actually land at `<bundle>/Resources/AssetDigests/*.json`.
    ///
    /// A resource that genuinely fails to load (missing from the bundle,
    /// unreadable, or not valid JSON) is a build/packaging regression, not
    /// a legitimate runtime data condition — every locale named by
    /// ``AssetLocale/digestResourceName`` ships a resource by construction,
    /// even when its content is deliberately an empty array (e.g. `ko`,
    /// which has no localized card art yet). Silently substituting `[]`
    /// for that failure would make a broken bundle indistinguishable from
    /// a locale that intentionally has nothing to localize, quietly
    /// disabling localization instead of surfacing the regression. So
    /// this throws a typed, catchable error instead of trapping the
    /// process; `ko.json` decodes successfully to `[]` and never reaches
    /// any of the throw sites below.
    private static func load(resourceName: String, bundle: Bundle) throws -> [String] {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: "json",
            subdirectory: "Resources/AssetDigests"
        ) else {
            throw AssetError.configurationFailure(
                "Missing bundled digest resource '\(resourceName).json': packaging regression"
            )
        }
        guard let data = try? Data(contentsOf: url) else {
            throw AssetError.configurationFailure(
                "Bundled digest resource '\(resourceName).json' could not be read: "
                    + "packaging regression"
            )
        }
        guard let identifiers = try? JSONDecoder().decode([String].self, from: data) else {
            throw AssetError.configurationFailure(
                "Bundled digest resource '\(resourceName).json' is not valid JSON: "
                    + "packaging regression"
            )
        }
        return identifiers
    }

    private static func asAssetError(_ error: any Error) -> AssetError {
        (error as? AssetError) ?? .configurationFailure(String(describing: error))
    }
}
