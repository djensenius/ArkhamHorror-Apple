import Foundation

/// One catalog document as it arrived: status, the headers this client is allowed to reason
/// about, the URL the bytes actually came from, and the exact bytes.
struct LocaleCatalogResponse: Sendable, Equatable {
    let statusCode: Int
    let contentType: String?
    let contentTypeOptions: String?
    /// The URL the response was ultimately produced by. Compared against the named origin so
    /// a transport that follows a redirect anyway cannot silently substitute another server.
    let url: URL?
    let data: Data
}

/// The bounded public JSON transport seam for catalog documents and site settings.
///
/// Deliberately **not** ``HTTPTransport``: this boundary is unauthenticated by construction
/// and must never share mutable state with the authenticated session transport. Modelling it
/// as a separate protocol means an authenticated transport cannot be passed here by accident,
/// and a test can inject a fake without touching the network at all.
protocol LocaleCatalogTransporting: Sendable {
    /// Fetches `url`, reading at most `maxBytes` and refusing anything longer.
    ///
    /// - Throws: ``LocaleCatalogFailure`` for a transport-level or policy failure, or
    ///   `CancellationError` when the enclosing task is cancelled. A non-200 status is
    ///   returned rather than thrown so the caller decides.
    func fetch(_ url: URL, maxBytes: Int) async throws -> LocaleCatalogResponse
}

/// The production transport: a dedicated, unauthenticated, cookie-, credential- and
/// cache-free ephemeral `URLSession` used for nothing else.
///
/// Every isolation property here is deliberate:
/// - `URLSessionConfiguration.ephemeral` with `httpCookieStorage`, `urlCredentialStorage`,
///   and `urlCache` all `nil`, and `httpShouldSetCookies = false`, so no cookie, credential,
///   or cached response can be read from or written to any shared store. A catalog fetch can
///   therefore never reuse the authenticated transport's mutable state, and never seed it.
/// - No `Authorization` header is ever set. The catalog routes are served unauthenticated
/// static JSON (or public site settings) and carry no cookies, tokens, or request-specific data.
/// - Redirects are refused outright by the delegate, so a 3xx is surfaced as a response this
///   client rejects rather than followed to a host the advertisement never named.
/// - TLS validation is never bypassed; the configuration inherits the default trust policy.
/// - An explicit request and resource timeout bounds every fetch.
/// - The body is read incrementally and abandoned the moment it exceeds the caller's ceiling,
///   so an unbounded or lying `Content-Length` can never force an unbounded allocation.
struct URLSessionLocaleCatalogTransport: LocaleCatalogTransporting {
    private let session: URLSession
    private let timeout: TimeInterval

    init(timeout: TimeInterval = LocaleCatalogLimits.requestTimeout) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpAdditionalHeaders = [:]
        session = URLSession(
            configuration: configuration,
            delegate: RedirectRejectingURLSessionDelegate(),
            delegateQueue: nil
        )
        self.timeout = timeout
    }

    func fetch(_ url: URL, maxBytes: Int) async throws -> LocaleCatalogResponse {
        let request = request(for: url)

        let stream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (stream, response) = try await session.bytes(for: request)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            try Task.checkCancellation()
            throw LocaleCatalogFailure.transportFailure
        }
        guard let http = response as? HTTPURLResponse else {
            throw LocaleCatalogFailure.transportFailure
        }
        // A declared length above the ceiling is refused before a single byte is buffered, so
        // an oversized document's cost to this client is O(1). A *lying* or absent length is
        // still bounded, by the incremental read below.
        if http.expectedContentLength > Int64(maxBytes) {
            throw LocaleCatalogFailure.tooLarge
        }
        let reservation = http.expectedContentLength > 0
            ? min(Int(http.expectedContentLength), maxBytes)
            : 0
        let data = try await Self.readBounded(stream, maxBytes: maxBytes, reserving: reservation)
        return LocaleCatalogResponse(
            statusCode: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            contentTypeOptions: http.value(forHTTPHeaderField: "X-Content-Type-Options"),
            url: http.url,
            data: data
        )
    }

    func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout
        return request
    }

    /// Reads at most `maxBytes`, throwing ``LocaleCatalogFailure/tooLarge`` the moment one more
    /// byte arrives. Accumulates into a `[UInt8]` reserved at the *response's* declared size
    /// (never at the ceiling), so a small document costs a small allocation and a lying
    /// `Content-Length` cannot preallocate 8 MiB.
    private static func readBounded(
        _ stream: URLSession.AsyncBytes, maxBytes: Int, reserving: Int
    ) async throws -> Data {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(reserving)
        do {
            for try await byte in stream {
                guard buffer.count < maxBytes else { throw LocaleCatalogFailure.tooLarge }
                buffer.append(byte)
            }
        } catch let failure as LocaleCatalogFailure {
            throw failure
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            try Task.checkCancellation()
            throw LocaleCatalogFailure.transportFailure
        }
        try Task.checkCancellation()
        return Data(buffer)
    }
}
