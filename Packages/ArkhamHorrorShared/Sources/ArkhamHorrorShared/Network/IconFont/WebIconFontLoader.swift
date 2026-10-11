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
    func fetch(_ url: URL, maxBytes: Int) async throws -> WebIconFontHTTPResponse
}

struct WebIconFontHTTPResponse: Sendable, Equatable {
    let statusCode: Int
    let etag: String?
    let data: Data
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
        if let data = await cachedData(for: url) {
            do {
                return try registrar.validateAndRegister(
                    data,
                    expectedFamily: source.family,
                    requiredGlyphs: Self.requiredGlyphs(for: source.family)
                )
            } catch {
                latestKeyByURL[url] = nil
                try? diskCache?.remove(url: url)
            }
        }

        let response: WebIconFontHTTPResponse
        do {
            response = try await transport.fetch(url, maxBytes: Self.maxFontBytes)
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
        let key = WebIconFontCacheKey(url: url, etag: response.etag, data: response.data)
        memoryCache[key] = response.data
        latestKeyByURL[url] = key
        try? diskCache?.store(data: response.data, key: key)
        return registration
    }

    private static func requiredGlyphs(for family: WebIconFontFamily) -> [StoryIconGlyph] {
        StoryIconGlyph.all.filter { $0.family == family }
    }

    private func cachedData(for url: URL) async -> Data? {
        if let key = latestKeyByURL[url], let data = memoryCache[key] {
            return data
        }
        guard let stored = try? diskCache?.load(url: url) else { return nil }
        memoryCache[stored.key] = stored.data
        latestKeyByURL[url] = stored.key
        return stored.data
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

struct URLSessionWebIconFontTransport: WebIconFontTransporting {
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(
            configuration: configuration,
            delegate: RedirectRejectingURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    func fetch(_ url: URL, maxBytes: Int) async throws -> WebIconFontHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "font/ttf, font/woff2, application/octet-stream",
            forHTTPHeaderField: "Accept"
        )
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let stream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (stream, response) = try await session.bytes(for: request)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            try Task.checkCancellation()
            throw WebIconFontFailure.transportFailure
        }
        guard let http = response as? HTTPURLResponse else {
            throw WebIconFontFailure.transportFailure
        }
        if http.expectedContentLength > Int64(maxBytes) {
            stream.task.cancel()
            throw WebIconFontFailure.tooLarge
        }
        let data = try await Self.readBounded(stream, maxBytes: maxBytes)
        return WebIconFontHTTPResponse(
            statusCode: http.statusCode,
            etag: http.value(forHTTPHeaderField: "ETag"),
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
        let ctFont = CTFontCreateWithGraphicsFont(cgFont, 17, nil, nil)
        let supportedScalars = Self.supportedScalars(
            requiredGlyphs.map(\.scalar),
            in: ctFont
        )
        guard !supportedScalars.isEmpty else { throw WebIconFontFailure.invalidFont }

        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterGraphicsFont(cgFont, &error) {
            let registrationError = error?.takeRetainedValue() as NSError?
            if registrationError?.code != CTFontManagerError.alreadyRegistered.rawValue {
                throw WebIconFontFailure.registrationFailed(registrationError?.code)
            }
        }
        return WebIconFontRegistration(
            family: expectedFamily,
            postScriptName: postScriptName,
            supportedScalars: supportedScalars
        )
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

    init(url: URL, etag: String?, data: Data) {
        urlString = url.absoluteString
        if let etag, !etag.isEmpty {
            validator = "etag:\(etag)"
        } else {
            validator = "sha256:\(Self.sha256Hex(data))"
        }
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
        let payloadName = Self.digest(key.urlString + "\n" + key.validator) + ".font"
        try data.write(to: root.appendingPathComponent(payloadName), options: [.atomic])
        let metadata = Metadata(key: key, payloadName: payloadName)
        let encoded = try JSONEncoder().encode(metadata)
        try encoded.write(to: metadataURL(for: key.urlString), options: [.atomic])
    }

    func load(url: URL) throws -> (key: WebIconFontCacheKey, data: Data)? {
        let metadataURL = metadataURL(for: url.absoluteString)
        guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
        do {
            let metadata = try JSONDecoder().decode(
                Metadata.self,
                from: Data(contentsOf: metadataURL)
            )
            guard metadata.key.urlString == url.absoluteString else {
                throw WebIconFontFailure.cacheCorrupted
            }
            let data = try Data(contentsOf: root.appendingPathComponent(metadata.payloadName))
            guard metadata.key.validator.hasPrefix("etag:")
                || metadata.key.validator == "sha256:\(Self.digestData(data))"
            else { throw WebIconFontFailure.cacheCorrupted }
            return (metadata.key, data)
        } catch {
            try? fileManager.removeItem(at: metadataURL)
            throw error
        }
    }

    func remove(url: URL) throws {
        try? fileManager.removeItem(at: metadataURL(for: url.absoluteString))
    }

    private func metadataURL(for urlString: String) -> URL {
        root.appendingPathComponent(Self.digest(urlString) + ".json")
    }

    private struct Metadata: Codable {
        let key: WebIconFontCacheKey
        let payloadName: String
    }

    private static func digest(_ value: String) -> String {
        digestData(Data(value.utf8))
    }

    private static func digestData(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
