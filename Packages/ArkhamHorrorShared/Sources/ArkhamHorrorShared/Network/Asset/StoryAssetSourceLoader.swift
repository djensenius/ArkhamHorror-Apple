import Foundation

/// Reads the same public site-settings endpoint as the web client. Catalog content
/// cannot select a host; only this selected-profile response can authorize one.
struct StoryAssetSourceLoader: Sendable {
    let transport: any LocaleCatalogTransporting
    private static let maxBytes = 16384

    init(transport: any LocaleCatalogTransporting = URLSessionLocaleCatalogTransport()) {
        self.transport = transport
    }

    func load(for profile: ServerProfile) async throws -> AssetSourceNamespace {
        let url = profile.endpointURL(path: "/site-settings")
        let response = try await transport.fetch(url, maxBytes: Self.maxBytes)
        try Task.checkCancellation()
        try validate(response, requestedURL: url)
        return try source(for: assetHost(in: response.data), profile: profile)
    }

    private func validate(_ response: LocaleCatalogResponse, requestedURL: URL) throws {
        guard response.url == requestedURL else { throw LocaleCatalogFailure.redirected }
        guard response.statusCode == 200 else {
            throw LocaleCatalogFailure.unexpectedStatus(response.statusCode)
        }
        guard response.data.count <= Self.maxBytes else { throw LocaleCatalogFailure.tooLarge }
        // Existing same-origin Arkham API deployments do not add the static catalog's
        // `nosniff` header to this API response. Reuse its closed JSON media-type grammar
        // without making that separate static-serving policy a compatibility requirement.
        guard LocaleCatalogLoader.isAcceptableJSONMediaType(response) else {
            throw LocaleCatalogFailure.unacceptableContentType
        }
    }

    private func assetHost(in data: Data) throws -> String? {
        guard let json = try? LosslessJSONParser.parse(data),
              case let .object(object) = json
        else { throw LocaleCatalogFailure.malformedJSON }
        switch object["assetHost"] {
        case nil, .null?:
            return nil
        case let .string(raw)?:
            return raw
        default:
            throw LocaleCatalogFailure.untrustedAssetSource
        }
    }

    private func source(for raw: String?, profile: ServerProfile) throws -> AssetSourceNamespace {
        guard let raw else {
            // The web client's explicit null/missing setting selects its hosted CDN.
            return .hosted
        }
        let base: String
        if raw.isEmpty {
            // An empty web assetHost makes /img/arkham root-relative, not relative
            // to a server profile's API deployment prefix.
            var origin = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false)
            origin?.path = ""
            guard let value = origin?.string else {
                throw LocaleCatalogFailure.untrustedAssetSource
            }
            base = value
        } else {
            guard raw.contains("://") else { throw LocaleCatalogFailure.untrustedAssetSource }
            base = raw
        }
        guard let source = try? AssetSourceNamespace(rawAssetBase: base) else {
            throw LocaleCatalogFailure.untrustedAssetSource
        }
        return source
    }
}

extension AssetCacheService {
    /// One bounded cache for all windows, injected by RootView. Failure leaves
    /// image-bearing stories unavailable rather than bypassing disk authority.
    static func production() -> AssetCacheService? {
        let limits = AssetCacheLimits.production
        guard let directory = try? AssetDiskCache.productionDirectory(),
              let disk = try? AssetDiskCache(directory: directory, limits: limits)
        else { return nil }
        return AssetCacheService(
            memoryCache: AssetMemoryCache(limits: limits), diskCache: disk, limits: limits
        )
    }
}
