import Foundation

struct WebIconFontLoadReport: Sendable, Equatable {
    let registrations: [WebIconFontFamily: WebIconFontRegistration]
    let failures: [WebIconFontFamily: WebIconFontFailure]

    var loadedFamilies: Set<WebIconFontFamily> {
        Set(registrations.keys)
    }

    var availability: WebIconFontAvailability {
        WebIconFontAvailability(registrations: registrations)
    }
}

enum WebIconFontFailure: Error, Sendable, Equatable, Hashable {
    case invalidURL
    case transportFailure
    case unexpectedStatus(Int)
    case tooLarge
    case invalidFont
    case registrationFailed(Int?)
    case cacheCorrupted
}

protocol WebIconFontLoading: Sendable {
    func loadFonts(for profile: ServerProfile) async -> WebIconFontLoadReport
}

/// The safe default for non-production ``AppModel`` construction.
struct DisabledWebIconFontLoader: WebIconFontLoading {
    func loadFonts(for _: ServerProfile) async -> WebIconFontLoadReport {
        WebIconFontLoadReport(registrations: [:], failures: [:])
    }
}

protocol WebIconFontTransporting: Sendable {
    func fetch(
        _ request: WebIconFontHTTPRequest,
        maxBytes: Int
    ) async throws -> WebIconFontHTTPResponse
}

struct WebIconFontHTTPRequest: Sendable, Equatable {
    let url: URL
    let ifNoneMatch: String?
    let ifModifiedSince: String?

    init(url: URL, ifNoneMatch: String? = nil, ifModifiedSince: String? = nil) {
        self.url = url
        self.ifNoneMatch = ifNoneMatch
        self.ifModifiedSince = ifModifiedSince
    }
}

struct WebIconFontHTTPResponse: Sendable, Equatable {
    let statusCode: Int
    let etag: String?
    let lastModified: String?
    let data: Data

    init(statusCode: Int, etag: String? = nil, lastModified: String? = nil, data: Data) {
        self.statusCode = statusCode
        self.etag = etag
        self.lastModified = lastModified
        self.data = data
    }
}

protocol WebIconFontRegistering: Sendable {
    func validateAndRegister(
        _ data: Data,
        expectedFamily: WebIconFontFamily,
        requiredGlyphs: [StoryIconGlyph]
    ) throws -> WebIconFontRegistration
}

/// Loads the same icon fonts the web origin serves, without bundling any font binary.
actor WebIconFontLoader: WebIconFontLoading {
    static let maxFontBytes = 512 * 1024

    private let transport: any WebIconFontTransporting
    private let registrar: any WebIconFontRegistering
    private let diskCache: WebIconFontDiskCache?
    private var memoryCache: [WebIconFontCacheKey: Data] = [:]
    private var latestKeyByURL: [URL: WebIconFontCacheKey] = [:]
    private var memoryRevalidatedURLs: Set<URL> = []
    private var pendingRevalidations: [Task<Void, Never>] = []

    init(
        transport: any WebIconFontTransporting,
        registrar: any WebIconFontRegistering = CoreTextWebIconFontRegistrar(),
        diskCache: WebIconFontDiskCache? = nil
    ) {
        self.transport = transport
        self.registrar = registrar
        self.diskCache = diskCache
    }

    static func production() -> WebIconFontLoader {
        WebIconFontLoader(
            transport: URLSessionWebIconFontTransport(),
            registrar: CoreTextWebIconFontRegistrar(),
            diskCache: WebIconFontDiskCache.defaultCache()
        )
    }

    func loadFonts(for profile: ServerProfile) async -> WebIconFontLoadReport {
        var registrations: [WebIconFontFamily: WebIconFontRegistration] = [:]
        var failures: [WebIconFontFamily: WebIconFontFailure] = [:]
        for source in WebIconFontSources.required {
            do {
                registrations[source.family] = try await load(source, for: profile)
            } catch let failure as WebIconFontFailure {
                failures[source.family] = failure
            } catch {
                failures[source.family] = .transportFailure
            }
        }
        return WebIconFontLoadReport(registrations: registrations, failures: failures)
    }

    private func load(
        _ source: WebIconFontSource,
        for profile: ServerProfile
    ) async throws -> WebIconFontRegistration {
        guard let url = Self.url(for: source, profile: profile) else {
            throw WebIconFontFailure.invalidURL
        }
        if let cached = await cachedFont(for: url) {
            do {
                let registration = try registrar.validateAndRegister(
                    cached.data,
                    expectedFamily: source.family,
                    requiredGlyphs: Self.requiredGlyphs(for: source.family)
                )
                startCacheRevalidationIfNeeded(source: source, url: url, cached: cached)
                return registration
            } catch {
                latestKeyByURL[url] = nil
                memoryCache[cached.key] = nil
                try? diskCache?.remove(url: url)
            }
        }

        return try await fetchAndRegister(source, url: url)
    }

    private static func requiredGlyphs(for family: WebIconFontFamily) -> [StoryIconGlyph] {
        StoryIconGlyph.all.filter { $0.family == family }
    }

    private func fetchAndRegister(
        _ source: WebIconFontSource,
        url: URL
    ) async throws -> WebIconFontRegistration {
        let response: WebIconFontHTTPResponse
        do {
            response = try await transport.fetch(
                WebIconFontHTTPRequest(url: url),
                maxBytes: Self.maxFontBytes
            )
        } catch let failure as WebIconFontFailure {
            throw failure
        } catch {
            throw WebIconFontFailure.transportFailure
        }
        guard response.statusCode == 200 else {
            throw WebIconFontFailure.unexpectedStatus(response.statusCode)
        }
        let registration = try registrar.validateAndRegister(
            response.data,
            expectedFamily: source.family,
            requiredGlyphs: Self.requiredGlyphs(for: source.family)
        )
        let key = WebIconFontCacheKey(
            url: url, etag: response.etag, lastModified: response.lastModified, data: response.data
        )
        memoryCache[key] = response.data
        latestKeyByURL[url] = key
        try? diskCache?.store(data: response.data, key: key)
        return registration
    }

    private func cachedFont(for url: URL) async -> CachedWebIconFont? {
        if let key = latestKeyByURL[url], let data = memoryCache[key] {
            return CachedWebIconFont(key: key, data: data, origin: .memory)
        }
        do {
            guard let stored = try diskCache?.load(url: url) else { return nil }
            memoryCache[stored.key] = stored.data
            latestKeyByURL[url] = stored.key
            return CachedWebIconFont(key: stored.key, data: stored.data, origin: .disk)
        } catch {
            latestKeyByURL[url] = nil
            try? diskCache?.remove(url: url)
            return nil
        }
    }

    func awaitPendingRevalidations() async {
        while !pendingRevalidations.isEmpty {
            let task = pendingRevalidations.removeFirst()
            await task.value
        }
    }

    func replaceCachedFontForTesting(
        url: URL,
        data: Data,
        etag: String?,
        lastModified: String? = nil
    ) {
        let key = WebIconFontCacheKey(
            url: url, etag: etag, lastModified: lastModified, data: data
        )
        memoryCache[key] = data
        latestKeyByURL[url] = key
        try? diskCache?.store(data: data, key: key)
    }

    private func startCacheRevalidationIfNeeded(
        source: WebIconFontSource,
        url: URL,
        cached: CachedWebIconFont
    ) {
        switch cached.origin {
        case .disk:
            _ = memoryRevalidatedURLs.insert(url)
        case .memory:
            guard memoryRevalidatedURLs.insert(url).inserted else { return }
        }
        let task = Task { [source, url, cached] in
            await self.revalidateCache(source: source, url: url, cached: cached)
        }
        pendingRevalidations.append(task)
    }

    /// Mirrors `AssetCacheService.performRevalidation`: a cache hit is served immediately,
    /// then its exact URL is conditionally re-requested with the stored validators.
    /// `304` keeps the existing payload; a valid `200` atomically replaces it; all other
    /// statuses or failures leave the cached font in place.
    private func revalidateCache(
        source: WebIconFontSource,
        url: URL,
        cached: CachedWebIconFont
    ) async {
        let request = WebIconFontHTTPRequest(
            url: url,
            ifNoneMatch: cached.key.etagHeader,
            ifModifiedSince: cached.key.lastModifiedHeader
        )
        let response: WebIconFontHTTPResponse
        do {
            response = try await transport.fetch(request, maxBytes: Self.maxFontBytes)
        } catch {
            return
        }
        switch response.statusCode {
        case 304:
            return
        case 200:
            do {
                _ = try registrar.validateAndRegister(
                    response.data,
                    expectedFamily: source.family,
                    requiredGlyphs: Self.requiredGlyphs(for: source.family)
                )
                guard latestKeyByURL[url] == cached.key else { return }
                let key = WebIconFontCacheKey(
                    url: url, etag: response.etag,
                    lastModified: response.lastModified, data: response.data
                )
                memoryCache[cached.key] = nil
                memoryCache[key] = response.data
                latestKeyByURL[url] = key
                try? diskCache?.store(data: response.data, key: key)
            } catch {
                return
            }
        default:
            return
        }
    }

    /// Uses the same configured-origin rule as the existing static roots:
    /// ``LocaleCatalogAdvertisement/resolvedManifestURL(for:)`` resolves root-relative
    /// catalog paths by replacing `ServerProfile.baseURL.path`, and
    /// ``StoryAssetSourceLoader`` treats the web's empty `assetHost` as the profile origin
    /// with an empty path. Production fonts are assumed to live on that configured web/static
    /// origin at `/fonts/<name>`; if a deployment hosts fonts elsewhere it must expose that
    /// origin through the configured server endpoint rather than this client guessing.
    static func url(for source: WebIconFontSource, profile: ServerProfile) -> URL? {
        guard var components = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.path = source.path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

private struct CachedWebIconFont: Sendable {
    enum Origin: Sendable {
        case memory
        case disk
    }

    let key: WebIconFontCacheKey
    let data: Data
    let origin: Origin
}
