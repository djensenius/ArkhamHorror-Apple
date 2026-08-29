/// A read-only lookup of which card-art identifiers have a localized image
/// for a given locale.
///
/// ``AssetLocator`` uses this to decide whether a localized candidate is
/// even worth constructing (per the issue's "skip a localized request when
/// its digest entry is absent" requirement) — never as a permission check
/// for anything else.
protocol LocalizedDigestLookup: Sendable {
    /// Whether `identifier`'s art has a published localized image for
    /// `locale`. Always `false` for ``AssetLocale/english``.
    func hasLocalizedArt(_ identifier: AssetIdentifier, locale: AssetLocale) -> Bool
}

/// Pure transformation from a raw upstream web-client digest (an array of
/// full relative paths like `"cards/01001.avif"`) to the compact set of
/// valid card-code identifiers this package ships as a resource.
///
/// This exact function is used both to produce the shipped compact
/// resources (see `Resources/AssetDigests/PROVENANCE.md`) and, in
/// `LocalizedDigestCompactorDriftTests`, to detect drift between the pinned
/// raw upstream fixtures and what is actually shipped.
enum LocalizedDigestCompactor {
    private static let cardPrefix = "cards/"
    private static let recognizedExtensions: Set<String> = ["avif", "jpg", "jpeg", "png"]

    /// Filters `rawEntries` to `cards/`-prefixed entries with a recognised
    /// image extension and a code matching ``AssetIdentifier/cardCode(_:)``,
    /// strips the prefix and extension, deduplicates, and sorts.
    ///
    /// Anything else (a different prefix, an unrecognised extension, or a
    /// malformed code) is silently dropped: a dropped entry only means that
    /// one variant is never treated as localized, which safely falls back
    /// to the English asset rather than failing.
    static func compactCardIdentifiers(fromRawEntries rawEntries: [String]) -> [String] {
        var identifiers = Set<String>()
        for entry in rawEntries {
            guard entry.hasPrefix(cardPrefix) else { continue }
            let rest = entry.dropFirst(cardPrefix.count)
            guard let dotIndex = rest.lastIndex(of: ".") else { continue }
            let code = String(rest[rest.startIndex ..< dotIndex])
            let ext = String(rest[rest.index(after: dotIndex)...])
            guard recognizedExtensions.contains(ext) else { continue }
            guard (try? AssetIdentifier.cardCode(code)) != nil else { continue }
            identifiers.insert(code)
        }
        return identifiers.sorted()
    }
}
