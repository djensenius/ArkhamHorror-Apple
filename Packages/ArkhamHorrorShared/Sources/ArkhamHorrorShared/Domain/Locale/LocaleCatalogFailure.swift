import Foundation

/// Why a locale catalog is not usable, in a closed vocabulary a presentation can announce.
///
/// Every case means exactly one thing: the catalog is unavailable. There is deliberately no
/// "partially usable" case — the backend's own boundary states that rendering a raw key, a
/// partial string, or a placeholder as though it were an instruction is a correctness bug in
/// the consumer, not a fallback — so this type exists to explain *why* Continue is disabled,
/// never to soften it.
///
/// Descriptions are sanitized: they never carry a URL, a host, a response body, or an
/// underlying `Error`'s `description`, because those can embed server-chosen text and this
/// value is rendered to the player and read aloud by VoiceOver.
enum LocaleCatalogFailure: Error, Sendable, Equatable, Hashable {
    /// The active server advertises no catalog at all (neither the `localeCatalog` object
    /// nor `i18n.locale-catalog.v1`), or advertises one this client refused to parse.
    case notAdvertised
    /// The manifest URL could not be resolved against the active profile's hosting context.
    case unresolvableManifestURL
    /// A response arrived over a redirect, or from an origin other than the one the
    /// advertisement named.
    case redirected
    /// The response status was not 200.
    case unexpectedStatus(Int)
    /// The response was not typed as JSON, or was served without `X-Content-Type-Options:
    /// nosniff`.
    case unacceptableContentType
    /// The response exceeded the byte ceiling for its kind before it was fully read.
    case tooLarge
    /// A genuine transport-level failure (DNS, TLS, connectivity, timeout).
    case transportFailure
    /// The manifest bytes did not hash to the digest the capabilities advertisement pinned.
    case manifestDigestMismatch
    /// A chunk's bytes did not hash to the digest the verified manifest pinned, or its size
    /// did not match.
    case chunkDigestMismatch
    /// A document was not well-formed JSON under this module's lossless parser (which also
    /// rejects duplicate object keys).
    case malformedJSON
    /// The manifest violated its closed v1 schema, its own totals, or its locale graph.
    case malformedManifest
    /// A chunk violated its closed v1 schema, or its identity did not match the descriptor
    /// that promised it.
    case malformedChunk
    /// The manifest disagreed with the capabilities advertisement about revision, default
    /// locale, or the published locale set.
    case advertisementMismatch
    /// The catalog does not publish a locale this client could resolve the user's preferred
    /// languages to.
    case localeUnavailable
    /// A cached entry was present but not usable, and was discarded rather than trusted.
    case cacheCorrupted
    /// The selected server's asset setting cannot authorize a safe native image source.
    case untrustedAssetSource

    /// A short, player-facing sentence explaining why the story cannot be shown.
    var announcement: String {
        switch self {
        case .notAdvertised:
            "This server does not publish the story text this app needs."
        case .unresolvableManifestURL:
            "The story text could not be downloaded from this server."
        case .redirected, .unacceptableContentType, .unexpectedStatus, .transportFailure:
            "The story content could not be downloaded from this server."
        case .tooLarge:
            "The story content this server published is larger than this app accepts."
        case .manifestDigestMismatch, .chunkDigestMismatch:
            "The story text did not match the checksum this server published."
        case .malformedJSON:
            "The story content this server published could not be verified."
        case .malformedManifest, .malformedChunk, .advertisementMismatch:
            "The story text this server published could not be verified."
        case .localeUnavailable:
            "This server publishes no story text for your language."
        case .cacheCorrupted:
            "The saved story text was discarded because it could not be verified."
        case .untrustedAssetSource:
            "The server's story image source could not be verified."
        }
    }

    /// Failures worth retrying against the same still-selected advertisement. A retry never
    /// broadens authority: it reuses the capability probe's exact profile-bound pointer.
    var isRetryable: Bool {
        switch self {
        case .unexpectedStatus, .transportFailure:
            true
        case .notAdvertised, .unresolvableManifestURL, .redirected,
             .unacceptableContentType, .tooLarge, .manifestDigestMismatch,
             .chunkDigestMismatch, .malformedJSON, .malformedManifest,
             .malformedChunk, .advertisementMismatch, .localeUnavailable,
             .cacheCorrupted, .untrustedAssetSource:
            false
        }
    }
}

/// Why one story could not be resolved, even where a catalog itself is available.
///
/// Distinct from ``LocaleCatalogFailure`` on purpose: a catalog that loaded perfectly can
/// still fail to render one specific story, and conflating the two would announce a download
/// problem for a content problem (or the reverse).
enum StoryUnavailableReason: Error, Sendable, Equatable, Hashable {
    /// No catalog is published or usable for the active server.
    case catalog(LocaleCatalogFailure)
    /// The catalog for this server is still being fetched and verified.
    case loading
    /// This app could not initialize its local bounded image pipeline.
    case imagePipelineUnavailable
    /// Only the image-source request is in flight; verified story text remains usable.
    case imageSourceLoading
    /// The key is absent from the selected locale, its fallback chain, and the default
    /// locale.
    case missingKey
    /// The catalog publishes this key as `{"form": "unsupported"}` — content it refused to
    /// reinterpret rather than half-render.
    case unsupportedEntry
    /// A `@:key` link chain revisited a key it had already rendered through.
    case linkCycle
    /// The message declares a variable the backend did not send.
    case missingVariable
    /// A variable's wire value has no unambiguous, lossless plain-text rendering.
    case unsupportedVariableValue
    /// The rendered result exceeded this client's node or depth bound.
    case tooComplex

    var announcement: String {
        switch self {
        case let .catalog(failure):
            failure.announcement
        case .loading:
            "The story text is still loading from this server."
        case .imagePipelineUnavailable:
            "This app could not initialize its local image cache. Retry image support to continue."
        case .imageSourceLoading:
            "The story image source is still loading."
        case .missingKey, .unsupportedEntry:
            "This server publishes no usable story text for this passage."
        case .linkCycle, .tooComplex:
            "This story text could not be safely displayed by this app version."
        case .missingVariable, .unsupportedVariableValue:
            "This story text needs a value this app version cannot display."
        }
    }
}
