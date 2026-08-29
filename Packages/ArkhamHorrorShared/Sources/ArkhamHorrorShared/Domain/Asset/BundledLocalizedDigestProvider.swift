import Foundation

/// Loads the compact per-locale digest resources bundled with this package
/// (see `Resources/AssetDigests/PROVENANCE.md`) and answers
/// ``LocalizedDigestLookup`` queries against them.
///
/// Each locale's identifier set is decoded lazily, once, on first use.
final class BundledLocalizedDigestProvider: LocalizedDigestLookup, @unchecked Sendable {
    /// Shared instance backing the default ``AssetLocator``.
    static let shared = BundledLocalizedDigestProvider()

    private let bundle: Bundle
    private let lock = NSLock()
    private var cache: [AssetLocale: Set<String>] = [:]

    init(bundle: Bundle = .module) {
        self.bundle = bundle
    }

    func hasLocalizedArt(_ identifier: AssetIdentifier, locale: AssetLocale) -> Bool {
        guard let identifiers = identifierSet(for: locale) else { return false }
        return identifiers.contains(identifier.rawValue)
    }

    /// The full loaded identifier set for `locale`, or `nil` for
    /// ``AssetLocale/english`` (which has no digest resource). Not `private`
    /// so `LocalizedDigestCompactorDriftTests` can compare it directly
    /// against a freshly recompacted raw fixture without needing to locate
    /// and re-decode this package's resource bundle itself.
    func identifierSet(for locale: AssetLocale) -> Set<String>? {
        guard let resourceName = locale.digestResourceName else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[locale] {
            return cached
        }
        let loaded = Self.load(resourceName: resourceName, bundle: bundle)
        cache[locale] = loaded
        return loaded
    }

    /// Loads `resourceName.json` from `bundle`.
    ///
    /// The subdirectory is `"Resources/AssetDigests"`, not just
    /// `"AssetDigests"`: `Package.swift` declares this target's resources as
    /// `.copy("Resources")`, which (unlike `.process`) preserves the copied
    /// directory's own name inside the resource bundle, so the digest files
    /// actually land at `<bundle>/Resources/AssetDigests/*.json`.
    private static func load(resourceName: String, bundle: Bundle) -> Set<String> {
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
        return Set(identifiers)
    }
}
