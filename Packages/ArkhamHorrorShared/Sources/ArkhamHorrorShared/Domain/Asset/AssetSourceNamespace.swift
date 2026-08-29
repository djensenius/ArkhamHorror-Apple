import Foundation

/// A canonicalized, validated identity for the asset CDN origin an
/// ``AssetKey`` is resolved against.
///
/// The cleartext (`http`) policy here is not a fresh grammar: it delegates to
/// the exact same raw-authority helpers that back ``ServerProfile``'s
/// validation (`ServerProfile+Normalization.swift`) — `withExplicitScheme`,
/// `assertStrictLoopbackAuthority`, `assertNoForbiddenComponents`, and
/// `validatedSchemeAndHost` are internal (not `private`) on that type
/// specifically so this asset-transport code, and any other consumer in this
/// module, can reuse one already-audited policy instead of maintaining a
/// second, subtly different one. Those helpers are pure URL-string
/// validation with no dependency on account/server presentation or session
/// composition, so reusing them does not touch any file this feature must
/// stay independent of.
///
/// The canonical string this type produces (scheme, lowercased host, an
/// always-explicit port, and a normalized path with no trailing slash) is
/// the namespace component folded into every cache key, so hosted and
/// self-hosted deployments — even ones that happen to share a base path —
/// can never collide on disk.
struct AssetSourceNamespace: Sendable, Equatable, Hashable {
    /// The fully normalized origin URL, e.g. `https://assets.arkhamhorror.app:443`.
    let canonicalOrigin: URL
    /// The normalized base path with no trailing slash (`""` for none).
    let basePath: String

    /// The default hosted CDN, matching the web client's production default
    /// (`frontend/src/stores/site_settings.ts`).
    static let hosted: AssetSourceNamespace = {
        guard
            let namespace = try? AssetSourceNamespace(
                rawAssetBase: "https://assets.arkhamhorror.app"
            )
        else {
            preconditionFailure("Hosted asset base literal must pass validation")
        }
        return namespace
    }()

    /// Validates and canonicalizes `rawValue` — the untrusted, never-yet-parsed
    /// site-settings/config input — and is the **only** entry point that may
    /// authorize cleartext `http`.
    ///
    /// This must take the raw `String`, not a `URL`: `URL(string:)` itself —
    /// not merely the `.host` accessor read from it afterward — already
    /// percent-decodes and Unicode-folds a raw authority at parse time (for
    /// example a full-width-dot `127。0。0。1` or a circled-letter lookalike of
    /// `localhost` both become the literal ASCII loopback text in
    /// `URL.absoluteString` itself, before any of this type's code ever runs).
    /// By the time a caller holds a `URL`, that folding has already happened
    /// and is indistinguishable from genuinely-typed loopback input, so no
    /// amount of re-inspecting a `URL`'s components can recover a trustworthy
    /// cleartext decision. See ``init(assetBase:)``, which therefore never
    /// authorizes `http` at all.
    ///
    /// - Throws: ``AssetError/invalidAssetBase`` if the scheme is unsupported,
    ///   `http` is used on anything other than the exact strict loopback
    ///   authorities `localhost`, a `127.0.0.0/8` dotted-quad, or `[::1]`
    ///   (see ``ServerProfile/assertStrictLoopbackAuthority(_:)``), the host
    ///   is missing/empty, the port is out of range, or credentials/query/
    ///   fragment are present.
    init(rawAssetBase rawValue: String) throws {
        let withScheme = try Self.asInvalidAssetBase {
            try ServerProfile.withExplicitScheme(rawValue)
        }
        guard let schemeSeparator = withScheme.range(of: "://") else {
            throw AssetError.invalidAssetBase
        }
        let rawScheme = withScheme[..<schemeSeparator.lowerBound].lowercased()
        let rawAuthority = withScheme[schemeSeparator.upperBound...].prefix { !"/?#".contains($0) }
        guard !rawAuthority.hasSuffix(":") else {
            throw AssetError.invalidAssetBase
        }
        // Validated against the raw, literal authority text — before
        // `URLComponents` ever sees it — for exactly the reason documented
        // above: Foundation's own percent-decoding, IDNA normalization, or
        // numeric-host canonicalization must never be allowed to turn a
        // non-loopback-looking authority into an accepted one.
        if rawScheme == "http" {
            try Self.asInvalidAssetBase {
                try ServerProfile.assertStrictLoopbackAuthority(rawAuthority)
            }
        }

        guard let components = URLComponents(string: withScheme) else {
            throw AssetError.invalidAssetBase
        }
        try Self.asInvalidAssetBase { try ServerProfile.assertNoForbiddenComponents(components) }
        // Secondary, defense-in-depth check on the Foundation-normalized host,
        // mirroring `ServerProfile`'s own two-layer design: the raw check
        // above is what actually closes the smuggling gap, but re-checking
        // here means a future change that removed/bypassed the raw check
        // would still fail closed rather than silently authorizing cleartext.
        let (scheme, lowercasedHost) = try Self.asInvalidAssetBase {
            try ServerProfile.validatedSchemeAndHost(components)
        }
        let effectivePort = try Self.effectivePort(scheme: scheme, components: components)

        var originComponents = URLComponents()
        originComponents.scheme = scheme
        originComponents.host = lowercasedHost
        originComponents.port = effectivePort
        guard let origin = originComponents.url else {
            throw AssetError.invalidAssetBase
        }
        canonicalOrigin = origin
        basePath = Self.normalizedPath(components.path)
    }

    /// Constructs from an already-parsed `URL` (for example a value read back
    /// from a typed configuration store).
    ///
    /// This entry point can **never** authorize cleartext `http`, regardless
    /// of host: see ``init(rawAssetBase:)`` for why a `URL`'s components can
    /// no longer be trusted to make that decision. A caller that legitimately
    /// needs the loopback `http` exception (for example validating raw
    /// site-settings text before it is ever turned into a `URL`) must use
    /// ``init(rawAssetBase:)`` directly on that original string.
    ///
    /// - Throws: ``AssetError/invalidAssetBase`` if `assetBase`'s scheme is
    ///   not `https`, or any of ``init(rawAssetBase:)``'s other validation
    ///   fails.
    init(assetBase: URL) throws {
        guard assetBase.scheme?.lowercased() == "https" else {
            throw AssetError.invalidAssetBase
        }
        try self.init(rawAssetBase: assetBase.absoluteString)
    }

    /// Runs `body`, converting any error it throws to
    /// ``AssetError/invalidAssetBase`` — the shared `ServerProfile` helpers
    /// this type reuses throw `ServerProfileError`, which is not a type this
    /// asset-transport code should expose to its own callers.
    private static func asInvalidAssetBase<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw AssetError.invalidAssetBase
        }
    }

    /// The explicit port if present and in range, otherwise the scheme's
    /// conventional default (443 for `https`, 80 for `http`).
    private static func effectivePort(scheme: String, components: URLComponents) throws -> Int {
        guard let explicitPort = components.port else {
            return scheme == "https" ? 443 : 80
        }
        guard (1 ... 65535).contains(explicitPort) else {
            throw AssetError.invalidAssetBase
        }
        return explicitPort
    }

    /// Collapses repeated `/` and trims any trailing slash, folding a bare
    /// `"/"` (or any all-slash path) down to `""`.
    ///
    /// This must exactly match how ``AssetCandidate/url(base:)`` builds the
    /// actual request URL: it splits `basePath` on `/` using the default
    /// `omittingEmptySubsequences: true`, which already collapses any
    /// repeated slash. If this identity did not collapse the same way, two
    /// spellings of the same effective base path (e.g. `/cdn/assets` and
    /// `/cdn//assets`) would build the identical request URL but fold into
    /// two different ``canonicalIdentity`` strings, silently duplicating
    /// disk cache entries for what is really the same namespace.
    private static func normalizedPath(_ path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !segments.isEmpty else { return "" }
        return "/" + segments.joined(separator: "/")
    }

    /// A stable string identity for this namespace, folded into the disk
    /// cache key. Includes scheme, host, always-explicit port, and base
    /// path so distinct deployments can never collide.
    var canonicalIdentity: String {
        "\(canonicalOrigin.absoluteString)\(basePath)"
    }
}
