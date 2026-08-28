import Foundation

/// A narrow HTTP transport interface shared by every network client in this package.
///
/// Callers inject a conformance to run deterministic unit tests without real network
/// I/O. The production conformance is ``URLSessionTransport``.
///
/// Implementations must not bypass TLS certificate validation and must not draw from
/// shared cookie, credential, or cache state. Application-level failures (non-2xx status
/// codes) are **not** thrown; the caller receives the response and decides how to handle
/// the status. Only genuine transport-level failures (network unreachable, DNS, TLS,
/// timeout) are thrown.
protocol HTTPTransport: Sendable {
    /// Executes the request and returns the raw response data and metadata.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// An ``HTTPTransport`` backed by a dedicated credential- and cookie-free ephemeral
/// `URLSession`.
///
/// The session is intentionally isolated from shared state:
/// - `URLSessionConfiguration.ephemeral` disables on-disk caching and does not persist
///   cookies or credentials across launches.
/// - `httpCookieStorage` is set to `nil` so no cookies are read from or written to any
///   store, even in-memory.
/// - `httpShouldSetCookies` is `false` so `Set-Cookie` response headers are ignored.
/// - `urlCredentialStorage` is `nil` so no stored credentials are injected automatically.
/// - `urlCache` is `nil` so no responses are cached.
///
/// TLS validation is never bypassed; the configuration inherits the default trust
/// evaluation policy. A single instance is safely shared by the public capability probe
/// and the authenticated session because it carries no shared credential state; the
/// `Authorization` header is set per-request only for authenticated operations.
struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// Creates a transport backed by a new ephemeral, credential- and cookie-free session.
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
