import Foundation

/// Every hard bound this client enforces on a locale catalog, mirroring the ceilings the
/// backend's own generator and `verify-dist.mjs` refuse to exceed.
///
/// These are not tuning knobs: a catalog that exceeds any of them is refused rather than
/// truncated, because the backend states it will never publish one that does. Enforcing
/// them here means a substituted or hostile response can never make this client allocate
/// more than a fixed, auditable amount of memory or disk regardless of what it claims.
enum LocaleCatalogLimits {
    /// The route the v1 manifest pins with `const` and this client therefore requires.
    static let basePath = "/locale-catalog"
    static let manifestPath = "/locale-catalog/manifest.json"
    static let chunkPathPrefix = "/locale-catalog/c/"
    static let digestAlgorithm = "sha256"
    static let schemaVersion = "1.0.0"
    static let generatorName = "arkham-locale-catalog"

    /// The capability identifier the `localeCatalog` advertisement is paired with. Neither
    /// half is trusted without the other.
    static let capabilityIdentifier = "i18n.locale-catalog.v1"

    /// Backend generation/verification ceiling for a single manifest document (8 MiB).
    static let maxManifestBytes = 8 * 1024 * 1024
    /// Backend generation/verification ceiling for a single chunk document (8 MiB).
    static let maxChunkBytes = 8 * 1024 * 1024
    /// Backend generation/verification ceiling for one whole catalog (192 MiB).
    static let maxCatalogBytes = 192 * 1024 * 1024
    /// Backend generation/verification ceiling on total catalog files (4096).
    static let maxCatalogFiles = 4096
    /// `manifest.schema.json`'s `locales.maxItems`, also the advertisement's
    /// `supportedLocales.maxItems`.
    static let maxLocales = 64
    /// `manifest.schema.json`'s per-locale `chunks.maxItems`.
    static let maxChunksPerLocale = 256
    /// `manifest.schema.json`'s `languageResolution` bound. The schema states only
    /// `minItems: 1`; a resolution table can name at most one entry per published locale
    /// per tag, so this client bounds it at the tag space a 64-locale catalog can address
    /// rather than leaving it unbounded.
    static let maxLanguageResolutionEntries = 4096
    /// The longest `manifestUrl` the capabilities schema accepts.
    static let maxManifestURLLength = 512

    /// The deepest chain of `@:key` links this client will follow before refusing the entry.
    ///
    /// Cycles are detected exactly (by the visited-key set), so this is a second, independent
    /// bound on a legal but pathological acyclic chain, not the cycle check itself.
    static let maxLinkDepth = 16

    /// The deepest render-AST node nesting this client will decode.
    static let maxNodeDepth = 32

    /// A single entry's declared runtime variables. The catalog format has no larger
    /// generator-side need; bounding it avoids allocating an attacker-sized declaration list.
    static let maxVariablesPerEntry = 256

    /// The most nodes one entry may expand to while rendering. A `linked` reference renders
    /// its target's whole subtree inline, so an acyclic graph can still fan out
    /// multiplicatively; this bounds the rendered result rather than the stored one.
    static let maxRenderedNodes = 4096

    /// The most chunks one resolver snapshot can hold. A fallback graph can legally visit
    /// every published locale, so this matches the manifest's whole-catalog file ceiling
    /// (minus the manifest itself) rather than assuming a two-locale fallback chain.
    static let maxSnapshotChunks = maxCatalogFiles - 1

    /// The request timeout applied to every catalog fetch.
    static let requestTimeout: TimeInterval = 30
}
