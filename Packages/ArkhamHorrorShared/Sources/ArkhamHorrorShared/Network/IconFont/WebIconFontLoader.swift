import CoreText
import CryptoKit
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

protocol WebIconFontTransporting: Sendable {
    func fetch(_ request: WebIconFontHTTPRequest, maxBytes: Int) async throws -> WebIconFontHTTPResponse
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
                if cached.origin == .disk {
                    startDiskCacheRevalidation(source: source, url: url, cached: cached)
                }
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
            response = try await transport.fetch(WebIconFontHTTPRequest(url: url), maxBytes: Self.maxFontBytes)
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

    private func startDiskCacheRevalidation(
        source: WebIconFontSource,
        url: URL,
        cached: CachedWebIconFont
    ) {
        Task { [source, url, cached] in
            await self.revalidateDiskCache(source: source, url: url, cached: cached)
        }
    }

    /// Mirrors `AssetCacheService.performRevalidation`: a disk hit is served immediately,
    /// then its exact URL is conditionally re-requested with the stored validators.
    /// `304` keeps the existing payload; a valid `200` atomically replaces it; all other
    /// statuses or failures leave the cached font in place.
    private func revalidateDiskCache(
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

struct URLSessionWebIconFontTransport: WebIconFontTransporting {
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        var configuration = URLSessionConfiguration.ephemeral
        Self.harden(&configuration, timeout: timeout)
        session = URLSession(
            configuration: configuration,
            delegate: RedirectRejectingURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    init(configuration: URLSessionConfiguration, timeout: TimeInterval = 15) {
        var configuration = configuration
        Self.harden(&configuration, timeout: timeout)
        session = URLSession(
            configuration: configuration,
            delegate: RedirectRejectingURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    private static func harden(_ configuration: inout URLSessionConfiguration, timeout: TimeInterval) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
    }

    func fetch(_ request: WebIconFontHTTPRequest, maxBytes: Int) async throws -> WebIconFontHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue(
            "font/ttf, font/woff2, application/octet-stream",
            forHTTPHeaderField: "Accept"
        )
        if let ifNoneMatch = request.ifNoneMatch {
            urlRequest.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        if let ifModifiedSince = request.ifModifiedSince {
            urlRequest.setValue(ifModifiedSince, forHTTPHeaderField: "If-Modified-Since")
        }
        urlRequest.httpShouldHandleCookies = false
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let stream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (stream, response) = try await session.bytes(for: urlRequest)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            try Task.checkCancellation()
            throw WebIconFontFailure.transportFailure
        }
        guard let http = response as? HTTPURLResponse else {
            throw WebIconFontFailure.transportFailure
        }
        let etag = http.value(forHTTPHeaderField: "ETag")
        let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        guard http.statusCode == 200 else {
            stream.task.cancel()
            return WebIconFontHTTPResponse(
                statusCode: http.statusCode, etag: etag, lastModified: lastModified, data: Data()
            )
        }
        if http.expectedContentLength > Int64(maxBytes) {
            stream.task.cancel()
            throw WebIconFontFailure.tooLarge
        }
        let data = try await Self.readBounded(stream, maxBytes: maxBytes)
        return WebIconFontHTTPResponse(
            statusCode: http.statusCode,
            etag: etag,
            lastModified: lastModified,
            data: data
        )
    }

    private static func readBounded(
        _ stream: URLSession.AsyncBytes,
        maxBytes: Int
    ) async throws -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(maxBytes, 64 * 1024))
        do {
            for try await byte in stream {
                guard bytes.count < maxBytes else {
                    stream.task.cancel()
                    throw WebIconFontFailure.tooLarge
                }
                bytes.append(byte)
            }
        } catch let failure as WebIconFontFailure {
            throw failure
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            try Task.checkCancellation()
            throw WebIconFontFailure.transportFailure
        }
        try Task.checkCancellation()
        return Data(bytes)
    }
}

struct CoreTextWebIconFontRegistrar: WebIconFontRegistering {
    func validateAndRegister(
        _ data: Data,
        expectedFamily: WebIconFontFamily,
        requiredGlyphs: [StoryIconGlyph]
    ) throws -> WebIconFontRegistration {
        let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData)
            as? [CTFontDescriptor]
        let provider = CGDataProvider(data: data as CFData)
        let cgFont = provider.flatMap(CGFont.init)
        guard descriptors?.isEmpty == false || cgFont != nil else {
            throw WebIconFontFailure.invalidFont
        }
        guard let cgFont, let postScriptName = cgFont.postScriptName as String? else {
            throw WebIconFontFailure.invalidFont
        }
        let byteFont = CTFontCreateWithGraphicsFont(cgFont, 17, nil, nil)
        let byteSupportedScalars = Self.supportedScalars(
            requiredGlyphs.map(\.scalar),
            in: byteFont
        )
        guard !byteSupportedScalars.isEmpty else { throw WebIconFontFailure.invalidFont }

        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterGraphicsFont(cgFont, &error) {
            let registrationError = error?.takeRetainedValue() as NSError?
            let code = registrationError?.code
            guard Self.isAlreadyRegistered(code), Self.resolvedFont(named: postScriptName) != nil
            else { throw WebIconFontFailure.registrationFailed(code) }
        }
        guard let resolvedFont = Self.resolvedFont(named: postScriptName) else {
            throw WebIconFontFailure.invalidFont
        }
        let supportedScalars = Self.supportedScalars(
            requiredGlyphs.map(\.scalar),
            in: resolvedFont
        )
        guard !supportedScalars.isEmpty else { throw WebIconFontFailure.invalidFont }
        return WebIconFontRegistration(
            family: expectedFamily,
            postScriptName: postScriptName,
            supportedScalars: supportedScalars
        )
    }

    private static func isAlreadyRegistered(_ code: Int?) -> Bool {
        code == CTFontManagerError.alreadyRegistered.rawValue
            || code == CTFontManagerError.duplicatedName.rawValue
    }

    private static func resolvedFont(named postScriptName: String) -> CTFont? {
        let font = CTFontCreateWithName(postScriptName as CFString, 17, nil)
        guard CTFontCopyPostScriptName(font) as String == postScriptName else { return nil }
        return font
    }

    private static func supportedScalars(
        _ scalars: [UnicodeScalar],
        in font: CTFont
    ) -> Set<UInt32> {
        Set(scalars.compactMap { scalar in
            let utf16 = Array(String(scalar).utf16)
            var glyphs = Array(repeating: CGGlyph(), count: utf16.count)
            var characters = utf16
            guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, utf16.count),
                  glyphs.allSatisfy({ $0 != 0 })
            else { return nil }
            return scalar.value
        })
    }
}

struct WebIconFontCacheKey: Sendable, Hashable, Codable {
    let urlString: String
    let validator: String
    let lastModified: String?

    init(url: URL, etag: String?, lastModified: String?, data: Data) {
        urlString = url.absoluteString
        let normalizedETag = etag.flatMap(Self.nonEmpty)
        let normalizedLastModified = lastModified.flatMap(Self.nonEmpty)
        self.lastModified = normalizedLastModified
        if let normalizedETag {
            validator = "etag:\(normalizedETag)"
        } else if let normalizedLastModified {
            validator = "last-modified:\(normalizedLastModified)"
        } else {
            validator = "sha256:\(Self.sha256Hex(data))"
        }
    }

    var etagHeader: String? {
        value(forPrefix: "etag:")
    }

    var lastModifiedHeader: String? {
        lastModified ?? value(forPrefix: "last-modified:")
    }

    private func value(forPrefix prefix: String) -> String? {
        guard validator.hasPrefix(prefix) else { return nil }
        return String(validator.dropFirst(prefix.count))
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct WebIconFontDiskCache: @unchecked Sendable {
    private let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    static func defaultCache() -> WebIconFontDiskCache? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return WebIconFontDiskCache(
            root: root.appendingPathComponent("WebIconFonts", isDirectory: true)
        )
    }

    func store(data: Data, key: WebIconFontCacheKey) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let metadataURL = metadataURL(for: key.urlString)
        let oldPayloadURL = existingPayloadURL(metadataURL: metadataURL)
        let newPayloadURL = payloadURL(for: key)
        try data.write(to: newPayloadURL, options: [.atomic])
        let metadata = Metadata(key: key)
        let encoded = try JSONEncoder().encode(metadata)
        try encoded.write(to: metadataURL, options: [.atomic])
        if let oldPayloadURL, oldPayloadURL != newPayloadURL {
            try? fileManager.removeItem(at: oldPayloadURL)
        }
    }

    func load(url: URL) throws -> (key: WebIconFontCacheKey, data: Data)? {
        let metadataURL = metadataURL(for: url.absoluteString)
        guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
        var decodedKey: WebIconFontCacheKey?
        do {
            let metadata = try JSONDecoder().decode(
                Metadata.self,
                from: Data(contentsOf: metadataURL)
            )
            decodedKey = metadata.key
            guard metadata.key.urlString == url.absoluteString else {
                throw WebIconFontFailure.cacheCorrupted
            }
            let data = try Data(contentsOf: payloadURL(for: metadata.key))
            guard metadata.key.validator.hasPrefix("etag:")
                || metadata.key.validator.hasPrefix("last-modified:")
                || metadata.key.validator == "sha256:\(Self.digestData(data))"
            else { throw WebIconFontFailure.cacheCorrupted }
            return (metadata.key, data)
        } catch {
            try? fileManager.removeItem(at: metadataURL)
            if let decodedKey {
                try? fileManager.removeItem(at: payloadURL(for: decodedKey))
            }
            throw error
        }
    }

    func remove(url: URL) throws {
        let metadataURL = metadataURL(for: url.absoluteString)
        if let payloadURL = existingPayloadURL(metadataURL: metadataURL) {
            try? fileManager.removeItem(at: payloadURL)
        }
        try? fileManager.removeItem(at: metadataURL)
    }

    private func metadataURL(for urlString: String) -> URL {
        root.appendingPathComponent(Self.digest(urlString) + ".json")
    }

    private func payloadURL(for key: WebIconFontCacheKey) -> URL {
        root.appendingPathComponent(Self.digest(key.urlString + "\n" + key.validator) + ".font")
    }

    private func existingPayloadURL(metadataURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data)
        else { return nil }
        return payloadURL(for: metadata.key)
    }

    private struct Metadata: Codable {
        let key: WebIconFontCacheKey
    }

    private static func digest(_ value: String) -> String {
        digestData(Data(value.utf8))
    }

    private static func digestData(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
