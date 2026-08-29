import Foundation

/// A canonicalized, validated identity for the asset CDN origin an
/// ``AssetKey`` is resolved against.
///
/// This is intentionally a fresh, narrowly-scoped implementation rather than
/// a reuse of ``ServerProfile``'s private URL-normalization helpers: those
/// helpers are private to that type and used by the account/server
/// presentation and session composition flows this feature must not touch.
/// The validation rules below mirror ``ServerProfile``'s strictness
/// (lowercased scheme/host, no credentials/query/fragment, explicit port
/// range) but add the asset-transport-specific cleartext restriction: `http`
/// is accepted only for the exact loopback authorities `localhost`,
/// `127.0.0.1`, and `::1`, so a self-hosted CDN can be exercised from a
/// simulator or local development server without ever weakening the policy
/// for any other host.
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
        guard let url = URL(string: "https://assets.arkhamhorror.app") else {
            preconditionFailure("Hosted asset base literal is compile-time valid")
        }
        guard let namespace = try? AssetSourceNamespace(assetBase: url) else {
            preconditionFailure("Hosted asset base literal must pass validation")
        }
        return namespace
    }()

    /// Validates and canonicalizes `assetBase` (typically an injected
    /// site-settings asset host, or ``hosted``).
    ///
    /// - Throws: ``AssetError/invalidAssetBase`` if the scheme is unsupported,
    ///   `http` is used on a non-loopback host, the host is missing/empty,
    ///   the port is out of range, or credentials/query/fragment are present.
    init(assetBase: URL) throws {
        let components = try Self.validatedComponents(from: assetBase)
        let lowercasedHost = try Self.validatedLowercasedHost(components)
        let scheme = try Self.validatedScheme(components, lowercasedHost: lowercasedHost)
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

    /// Parses `url` into `URLComponents` and rejects any credentials, query,
    /// or fragment, none of which have a meaning for a CDN base origin.
    private static func validatedComponents(from url: URL) throws -> URLComponents {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AssetError.invalidAssetBase
        }
        guard
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            throw AssetError.invalidAssetBase
        }
        return components
    }

    /// The non-empty, lowercased host, exactly as `URLComponents.host`
    /// returns it. Apple's public documentation for `URLComponents.host`
    /// describes IPv6 literals as unbracketed, but the actual Foundation
    /// behavior on this project's supported platforms/OS versions returns
    /// them still bracketed (e.g. `"[::1]"`) — verified directly by
    /// ``AssetSourceNamespaceTests``'s IPv6-loopback cases, which fail if
    /// that ever changes. `bareHost(_:)` below strips a bracket pair only
    /// for the ``loopbackHosts`` comparison, and is a safe no-op if the
    /// host were ever unbracketed instead; separately, if `.host` were
    /// ever unbracketed, assigning it straight back into
    /// `URLComponents.host` fails to build a URL at all (`.url` is `nil`),
    /// so this class fails safe — surfacing ``AssetError/invalidAssetBase``
    /// — rather than silently mis-canonicalizing such a host.
    private static func validatedLowercasedHost(_ components: URLComponents) throws -> String {
        guard let host = components.host, !host.isEmpty else {
            throw AssetError.invalidAssetBase
        }
        return host.lowercased()
    }

    /// Validates the scheme, applying the cleartext (`http`) exception only
    /// to the exact loopback authorities in ``loopbackHosts``.
    private static func validatedScheme(
        _ components: URLComponents,
        lowercasedHost: String
    ) throws -> String {
        guard let scheme = components.scheme?.lowercased() else {
            throw AssetError.invalidAssetBase
        }
        switch scheme {
        case "https":
            return scheme
        case "http":
            // On this project's supported Foundation (see the doc comment
            // on `validatedLowercasedHost(_:)`), an IPv6 literal keeps its
            // brackets in `lowercasedHost`, which the bracket-free
            // ``loopbackHosts`` set would never match; strip a single
            // surrounding bracket pair, if present, only for this
            // comparison (the bracketed form, whatever `.host` actually
            // produced, is still what gets used to build the canonical
            // origin URL).
            guard loopbackHosts.contains(bareHost(lowercasedHost)) else {
                throw AssetError.invalidAssetBase
            }
            return scheme
        default:
            throw AssetError.invalidAssetBase
        }
    }

    /// Strips a single surrounding `[...]` bracket pair, if present.
    private static func bareHost(_ lowercasedHost: String) -> String {
        guard lowercasedHost.hasPrefix("["), lowercasedHost.hasSuffix("]") else {
            return lowercasedHost
        }
        return String(lowercasedHost.dropFirst().dropLast())
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

    /// Trims any trailing slashes, folding a bare `"/"` down to `""`.
    private static func normalizedPath(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result == "/" ? "" : result
    }

    /// The exact loopback authorities the cleartext (`http`) exception
    /// applies to. Deliberately exact-match only: no wildcard subdomain, no
    /// broader `127.0.0.0/8` range, matching the issue's "exact cleartext
    /// loopback forms" requirement.
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// A stable string identity for this namespace, folded into the disk
    /// cache key. Includes scheme, host, always-explicit port, and base
    /// path so distinct deployments can never collide.
    var canonicalIdentity: String {
        "\(canonicalOrigin.absoluteString)\(basePath)"
    }
}
