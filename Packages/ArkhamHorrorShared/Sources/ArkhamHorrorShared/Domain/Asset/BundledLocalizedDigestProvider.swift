import Foundation

/// Loads the compact per-locale digest resources bundled with this package
/// (see `Resources/AssetDigests/PROVENANCE.md`) and answers
/// ``LocalizedDigestLookup`` queries against them.
///
/// Each locale's identifier list is decoded lazily, once, on first use, and
/// cached in both its original shipped order and as a `Set` for O(1)
/// membership lookups.
final class BundledLocalizedDigestProvider: LocalizedDigestLookup, @unchecked Sendable {
    /// Shared instance backing the default ``AssetLocator``.
    static let shared = BundledLocalizedDigestProvider()

    private let bundle: Bundle
    private let lock = NSLock()
    private var orderedCache: [AssetLocale: [String]] = [:]
    private var lookupCache: [AssetLocale: Set<String>] = [:]

    init(bundle: Bundle = .module) {
        self.bundle = bundle
    }

    func hasLocalizedArt(_ identifier: AssetIdentifier, locale: AssetLocale) -> Bool {
        guard let identifiers = identifierSet(for: locale) else { return false }
        return identifiers.contains(identifier.rawValue)
    }

    /// The full loaded identifier set for `locale`, or `nil` for
    /// ``AssetLocale/english`` (which has no digest resource).
    func identifierSet(for locale: AssetLocale) -> Set<String>? {
        loadIfNeeded(for: locale)?.set
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
        loadIfNeeded(for: locale)?.ordered
    }

    private func loadIfNeeded(for locale: AssetLocale) -> (ordered: [String], set: Set<String>)? {
        guard let resourceName = locale.digestResourceName else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let ordered = orderedCache[locale], let set = lookupCache[locale] {
            return (ordered, set)
        }
        let ordered = Self.load(resourceName: resourceName, bundle: bundle)
        let set = Set(ordered)
        orderedCache[locale] = ordered
        lookupCache[locale] = set
        return (ordered, set)
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
    private static func load(resourceName: String, bundle: Bundle) -> [String] {
        guard
            let url = bundle.url(
                forResource: resourceName,
                withExtension: "json",
                subdirectory: "Resources/AssetDigests"
            ),
            let data = try? Data(contentsOf: url),
            let identifiers = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return identifiers
    }
}
