import Foundation

/// A single asset HTTP request. Only conditional-revalidation headers and
/// the target URL are exposed; there is no way to attach cookies,
/// credentials, or arbitrary headers through this type.
struct AssetHTTPRequest: Sendable, Equatable {
    let url: URL
    /// `If-None-Match`, when revalidating a cached entry with an `ETag`.
    let ifNoneMatch: String?
    /// `If-Modified-Since`, when revalidating a cached entry with a
    /// `Last-Modified` value and no `ETag`.
    let ifModifiedSince: String?

    init(url: URL, ifNoneMatch: String? = nil, ifModifiedSince: String? = nil) {
        self.url = url
        self.ifNoneMatch = ifNoneMatch
        self.ifModifiedSince = ifModifiedSince
    }
}

/// The outcome of a single candidate fetch attempt.
enum AssetHTTPResult: Sendable, Equatable {
    /// A 2xx response with a validated-length body and select headers.
    case success(AssetHTTPResponse)
    /// A 304 response (only meaningful when the request carried a
    /// conditional header).
    case notModified
    /// A 404 response for this specific candidate; callers may advance to
    /// the next candidate.
    case notFound
}

struct AssetHTTPResponse: Sendable, Equatable {
    let body: Data
    let contentType: String?
    let etag: String?
    let lastModified: String?
}

/// A narrow, credential-free transport interface for asset fetches.
///
/// Implementations must:
/// - never send cookies, cached credentials, or an `Authorization` header;
/// - reject every HTTP redirect (3xx is always a failure, even for a
///   condition that would otherwise look like `notModified`);
/// - enforce ``AssetCacheLimits/maxEncodedBytes`` while bytes are arriving,
///   not after buffering an unbounded ``Data``;
/// - never bypass TLS certificate validation.
protocol AssetTransport: Sendable {
    func fetch(_ request: AssetHTTPRequest, limits: AssetCacheLimits) async throws
        -> AssetHTTPResult
}

/// Refuses redirects (like ``RedirectRejectingURLSessionDelegate``) and
/// denies every authentication challenge except default server-trust
/// evaluation, so TLS validation still runs but no credential of any kind
/// — basic, digest, client-certificate, or otherwise — is ever supplied.
final class AssetTaskDelegate: NSObject, @unchecked Sendable {}

extension AssetTaskDelegate: URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            // Defers to the system's default TLS trust evaluation; this is
            // not a bypass.
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// The production ``AssetTransport``, backed by a dedicated ephemeral,
/// cookie- and credential-free `URLSession` with incremental byte-cap
/// enforcement and strict status handling.
struct URLSessionAssetTransport: AssetTransport {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    func fetch(
        _ request: AssetHTTPRequest,
        limits: AssetCacheLimits
    ) async throws -> AssetHTTPResult {
        let urlRequest = Self.urlRequest(for: request)
        let (asyncBytes, response) = try await Self.performRequest(urlRequest, session: session)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AssetError.nonHTTPResponse
        }

        return try await Self.result(for: httpResponse, bytes: asyncBytes, limits: limits)
    }

    /// Builds the outgoing request: a plain `GET` with cookies disabled and
    /// only the optional conditional-revalidation headers attached.
    private static func urlRequest(for request: AssetHTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        urlRequest.httpShouldHandleCookies = false
        if let ifNoneMatch = request.ifNoneMatch {
            urlRequest.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        if let ifModifiedSince = request.ifModifiedSince {
            urlRequest.setValue(ifModifiedSince, forHTTPHeaderField: "If-Modified-Since")
        }
        return urlRequest
    }

    /// Starts the streaming request, translating cancellation and transport
    /// failures the same way ``readBody(_:response:limits:)`` does.
    private static func performRequest(
        _ urlRequest: URLRequest,
        session: URLSession
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await session.bytes(for: urlRequest, delegate: AssetTaskDelegate())
        } catch {
            try mapTransportError(error)
        }
    }

    /// Turns a validated HTTP response into an ``AssetHTTPResult``, reading
    /// and validating the body only for a 2xx status.
    private static func result(
        for httpResponse: HTTPURLResponse,
        bytes: URLSession.AsyncBytes,
        limits: AssetCacheLimits
    ) async throws -> AssetHTTPResult {
        switch httpResponse.statusCode {
        case 200 ... 299:
            let data = try await readBody(bytes, response: httpResponse, limits: limits)
            return .success(AssetHTTPResponse(
                body: data,
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                etag: httpResponse.value(forHTTPHeaderField: "ETag"),
                lastModified: httpResponse.value(forHTTPHeaderField: "Last-Modified")
            ))
        case 304:
            return .notModified
        case 404:
            return .notFound
        case 300 ... 399:
            throw AssetError.redirectRejected(status: httpResponse.statusCode)
        default:
            throw AssetError.unexpectedStatus(httpResponse.statusCode)
        }
    }

    /// Rejects a body whose declared `Content-Length` already exceeds the
    /// cap before reading anything, then delegates incremental enforcement
    /// to ``AssetByteCapReader``, translating its own transport-level
    /// failures (cancellation, connection errors) the same way the initial
    /// request does.
    private static func readBody(
        _ asyncBytes: URLSession.AsyncBytes,
        response: HTTPURLResponse,
        limits: AssetCacheLimits
    ) async throws -> Data {
        let declaredLength = response.expectedContentLength
        if declaredLength > 0, declaredLength > Int64(limits.maxEncodedBytes) {
            throw AssetError.responseTooLarge
        }
        do {
            return try await AssetByteCapReader.read(asyncBytes, limits: limits)
        } catch let assetError as AssetError {
            throw assetError
        } catch {
            try mapTransportError(error)
        }
    }

    /// Normalizes any non-``AssetError`` failure from the underlying
    /// `URLSession` call into either propagated cancellation or a typed
    /// ``AssetError/transportFailure(_:)``. Always throws; never returns.
    private static func mapTransportError(_ error: Error) throws -> Never {
        if let cancellation = error as? CancellationError {
            throw cancellation
        }
        try Task.checkCancellation()
        if (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        }
        throw AssetError.transportFailure(String(describing: error))
    }
}
