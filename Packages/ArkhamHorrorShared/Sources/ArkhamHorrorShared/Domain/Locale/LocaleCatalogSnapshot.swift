import Foundation

private struct LocaleCatalogEntryKey: Sendable, Equatable, Hashable {
    let locale: String
    let key: String
}

/// A complete, internally coherent, immutable view of one catalog revision, bound to exactly
/// one server endpoint, one catalog revision, one selected locale, one manifest digest, and
/// the complete verified chunk set that locale needs.
///
/// **A revision is never partially published.** A snapshot only ever comes into existence
/// once every chunk it references has been downloaded, size-checked, digest-verified, and
/// identity-checked against the manifest that named it. There is no mutable state inside it
/// and no way to add a chunk afterwards, so a reader can never observe a title resolved from
/// one revision beside a body resolved from another: the two either come from this snapshot
/// or the story does not resolve at all.
///
/// Being a value type is what makes concurrent readers safe. Multiple scenes hold the same
/// immutable snapshot rather than sharing a mutable resolver, so a catalog replacement
/// swaps a reference in the observable model and every in-flight read either completes
/// against the old snapshot in full or is recomputed against the new one in full.
struct LocaleCatalogSnapshot: Sendable, Equatable {
    /// The exact endpoint/revision/locale/digest identity this snapshot is bound to.
    let identity: LocaleCatalogIdentity
    let manifest: LocaleCatalogManifest
    /// Every verified chunk, keyed by `(locale, pack)`.
    private let chunks: [LocaleCatalogChunkKey: LocaleCatalogChunk]
    /// Lookup follows the verified chunks themselves rather than guessing a pack from a
    /// dotted key. This is required for core namespaces such as `label.*`.
    private let entries: [LocaleCatalogEntryKey: LocaleCatalogEntry]
    private let duplicateEntryKeys: Set<LocaleCatalogEntryKey>

    init(
        identity: LocaleCatalogIdentity,
        manifest: LocaleCatalogManifest,
        chunks: [LocaleCatalogChunkKey: LocaleCatalogChunk]
    ) {
        self.identity = identity
        self.manifest = manifest
        self.chunks = chunks
        var entries: [LocaleCatalogEntryKey: LocaleCatalogEntry] = [:]
        var duplicates: Set<LocaleCatalogEntryKey> = []
        for chunk in chunks.values {
            for (key, entry) in chunk.entries {
                let entryKey = LocaleCatalogEntryKey(locale: chunk.locale, key: key)
                if entries.updateValue(entry, forKey: entryKey) != nil {
                    duplicates.insert(entryKey)
                }
            }
        }
        self.entries = entries
        duplicateEntryKeys = duplicates
    }

    /// The locale chain a lookup walks: the selected locale, then its fallbacks, ending at
    /// the default locale. Built from the manifest's own graph, which validation already
    /// proved acyclic and default-terminating.
    var localeChain: [String] {
        manifest.localeChain(from: identity.locale)
    }

    func entry(for key: String, locale: String) -> LocaleCatalogEntry? {
        let entryKey = LocaleCatalogEntryKey(locale: locale, key: key)
        guard !duplicateEntryKeys.contains(entryKey) else { return nil }
        return entries[entryKey]
    }

    /// Whether this snapshot holds every chunk the manifest lists for every locale in its own
    /// resolution chain. Checked at construction time by the loader; re-checkable here so a
    /// restored cache entry can be held to exactly the same completeness bar.
    var isComplete: Bool {
        for locale in localeChain {
            guard let record = manifest.record(for: locale) else { return false }
            for descriptor in record.chunks {
                let key = LocaleCatalogChunkKey(locale: locale, pack: descriptor.pack)
                guard let chunk = chunks[key],
                      chunk.locale == key.locale,
                      chunk.pack == key.pack
                else { return false }
            }
        }
        return !chunks.isEmpty
            && chunks.count <= LocaleCatalogLimits.maxSnapshotChunks
            && duplicateEntryKeys.isEmpty
    }
}

/// `(locale, pack)`: the coordinates of exactly one chunk.
struct LocaleCatalogChunkKey: Sendable, Equatable, Hashable {
    let locale: String
    let pack: String
}

/// Everything a catalog snapshot is bound to. Any difference in any component is a different
/// catalog, and is what a cache key, a profile switch, and a revision replacement all compare.
struct LocaleCatalogIdentity: Sendable, Equatable, Hashable {
    /// The canonical absolute URL of the manifest this catalog was fetched from, including
    /// scheme, host, port, and path prefix — the server endpoint identity, not merely a
    /// profile UUID, so two profiles pointing at one deployment share a cache entry and one
    /// profile edited to point elsewhere never does.
    let endpoint: String
    let catalogRevision: String
    let locale: String
    let manifestSha256: String

    init(endpoint: URL, catalogRevision: String, locale: String, manifestSha256: String) {
        self.endpoint = endpoint.absoluteString
        self.catalogRevision = catalogRevision
        self.locale = locale
        self.manifestSha256 = manifestSha256
    }
}

// MARK: - Language resolution

extension LocaleCatalogSnapshot {
    /// Selects the catalog locale for `preferredLanguages`, matching the manifest's own
    /// `languageResolution` table and the web client's fallback semantics.
    ///
    /// The table is generated by calling production `preferredLanguage`/`uiLocaleFor`, so
    /// matching it exactly — rather than reimplementing BCP-47 matching — is what keeps a
    /// native client from drifting from the web client. Each preferred tag is tried in order:
    /// first as an exact table hit, then by progressively dropping trailing subtags
    /// (`zh-Hans-CN` → `zh-Hans` → `zh`), which is how the table's own `zh-Hans`/`zh-CN` rows
    /// generalize. Anything unresolved falls through to the default locale, exactly as the
    /// web client's "anything unsupported → `en`" rule does.
    ///
    /// Comparison is ASCII case-insensitive on the *tag*, never `String.lowercased()`, so a
    /// KELVIN SIGN or a Turkish dotless I in a user's system language list can never fold
    /// into an ASCII letter and match a published tag it is not.
    static func resolveLocale(
        preferredLanguages: [String],
        table: [String: String],
        supportedLocales: Set<String>,
        defaultLocale: String
    ) -> String {
        for language in preferredLanguages {
            guard let lowercasedLanguage = LocaleCatalogGrammar.asciiLowercased(language) else {
                continue
            }
            var subtags = LocaleCatalogGrammar.splitASCII(
                lowercasedLanguage, separator: 0x2D
            )
            while !subtags.isEmpty {
                var candidateBytes: [UInt8] = []
                for (index, subtag) in subtags.enumerated() {
                    if index > 0 {
                        candidateBytes.append(0x2D)
                    }
                    candidateBytes.append(contentsOf: subtag)
                }
                guard let candidate = String(bytes: candidateBytes, encoding: .utf8) else {
                    return defaultLocale
                }
                if let locale = table[candidate], supportedLocales.contains(locale) {
                    return locale
                }
                if supportedLocales.contains(candidate) {
                    return candidate
                }
                subtags.removeLast()
            }
        }
        return defaultLocale
    }
}
