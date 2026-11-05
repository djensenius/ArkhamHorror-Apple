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
/// identity-checked against the manifest that named it. There is no mutable state inside it,
/// so a reader can never observe a title resolved from one revision beside a body resolved
/// from another: the two either come from this snapshot or the story does not resolve at all.
/// The only way to add chunks is ``adding(chunks:)``, which returns a *new* snapshot of the same
/// identity with the chain's deferred packs (card names) filled in.
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

    /// Whether this snapshot holds every eager chunk the manifest lists for every locale in its
    /// own resolution chain. Checked at construction time by the loader; re-checkable here so a
    /// restored cache entry can be held to exactly the same completeness bar.
    ///
    /// A ``LocaleCatalogLimits/deferredPacks`` chunk may be missing: it is loaded on first
    /// lookup and added with ``adding(chunks:)``. A chunk that *is* held must still be one the
    /// chain lists. The chain must list at least one chunk, so a card-only locale such as `pl`
    /// (whose own record has only `cardNames`) is usable through its fallback's eager packs.
    var isComplete: Bool {
        guard let locations = chainChunkLocations, !locations.isEmpty else { return false }
        var listed: Set<LocaleCatalogChunkKey> = []
        for location in locations {
            let key = location.key
            listed.insert(key)
            if let chunk = chunks[key] {
                guard chunk.locale == key.locale, chunk.pack == key.pack else { return false }
            } else if !location.isDeferred {
                return false
            }
        }
        return chunks.keys.allSatisfy(listed.contains)
            && chunks.count <= LocaleCatalogLimits.maxSnapshotChunks
            && duplicateEntryKeys.isEmpty
    }

    /// Every chunk the manifest lists for this snapshot's chain, in chain order, or `nil` when
    /// a chain locale has no record.
    var chainChunkLocations: [LocaleCatalogChunkLocation]? {
        manifest.chunkLocations(chainFrom: identity.locale)
    }

    /// The chain chunks this snapshot holds, which is what the cache persists.
    var heldChunkLocations: [LocaleCatalogChunkLocation] {
        (chainChunkLocations ?? []).filter { chunks[$0.key] != nil }
    }

    /// The deferred-pack chunks the chain lists that this snapshot does not hold yet.
    var pendingDeferredChunks: [LocaleCatalogChunkLocation] {
        (chainChunkLocations ?? []).filter { $0.isDeferred && chunks[$0.key] == nil }
    }

    var hasPendingDeferredPacks: Bool {
        !pendingDeferredChunks.isEmpty
    }

    /// This snapshot plus *every* pending deferred chunk, or `nil` when `added` is not exactly
    /// that set, a chunk's identity does not match its coordinates, or the merged snapshot
    /// fails ``isComplete`` (for example a key duplicated across packs of one locale).
    ///
    /// All-or-nothing, so a reader never sees one chain locale's card names without the
    /// others. The caller has already size- and SHA-256-checked each chunk's exact bytes
    /// against its descriptor before validating it into a ``LocaleCatalogChunk``.
    func adding(
        chunks added: [LocaleCatalogChunkKey: LocaleCatalogChunk]
    ) -> LocaleCatalogSnapshot? {
        let pendingKeys = Set(pendingDeferredChunks.map(\.key))
        guard !pendingKeys.isEmpty, Set(added.keys) == pendingKeys else { return nil }
        for (key, chunk) in added {
            guard chunk.locale == key.locale, chunk.pack == key.pack else { return nil }
        }
        let merged = chunks.merging(added) { current, _ in current }
        let next = LocaleCatalogSnapshot(identity: identity, manifest: manifest, chunks: merged)
        guard next.isComplete else { return nil }
        return next
    }
}

extension LocaleCatalogManifest {
    /// Every chunk listed for `locale`'s resolution chain, in chain order, or `nil` when a
    /// chain locale has no record.
    func chunkLocations(chainFrom locale: String) -> [LocaleCatalogChunkLocation]? {
        var locations: [LocaleCatalogChunkLocation] = []
        for chainLocale in localeChain(from: locale) {
            guard let record = record(for: chainLocale) else { return nil }
            for descriptor in record.chunks {
                locations.append(LocaleCatalogChunkLocation(
                    locale: chainLocale, fallback: record.fallback, descriptor: descriptor
                ))
            }
        }
        return locations
    }
}

/// One chain chunk: the locale it belongs to, that locale's fallback, and its descriptor.
struct LocaleCatalogChunkLocation: Sendable, Equatable {
    let locale: String
    let fallback: String?
    let descriptor: LocaleCatalogChunkDescriptor

    var key: LocaleCatalogChunkKey {
        LocaleCatalogChunkKey(locale: locale, pack: descriptor.pack)
    }

    var isDeferred: Bool {
        LocaleCatalogLimits.deferredPacks.contains(descriptor.pack)
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
