import Foundation

/// A narrow transport interface for capability probe network calls.
///
/// The production implementation is ``URLSessionTransport``. Tests supply a stub
/// or failing conformance to exercise all probe code paths without real network I/O.
///
/// Implementations must not bypass TLS certificate validation and must not inject
/// authentication credentials; the capabilities endpoint is public.
protocol CapabilityProbeTransport: Sendable {
    /// Executes the request and returns the raw response data and metadata.
    ///
    /// Throws for transport-level failures (network unreachable, DNS, TLS, etc.).
    /// Application-level failures (non-2xx status codes) are **not** thrown; the
    /// caller receives the response and decides how to handle the status.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// A ``CapabilityProbeTransport`` backed by a dedicated credential- and cookie-free
/// ephemeral `URLSession`.
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
/// evaluation policy.
struct URLSessionTransport: CapabilityProbeTransport {
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
