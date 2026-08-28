import Foundation

/// A typed authentication HTTP client over an injectable ``HTTPTransport``.
///
/// Endpoint URLs are derived from the selected ``ServerProfile`` and the injected
/// ``ContractPin`` (the same pin the capability probe uses), so a session never targets a
/// hard-coded host. Every request sets `Accept: application/json`, disables cookie
/// handling, and — for authenticated operations only — sets exactly
/// `Authorization: Token <token>`. Public `authenticate`/`register` requests never carry
/// an `Authorization` header.
///
/// The default transport is a dedicated ephemeral ``URLSessionTransport`` that draws from
/// no shared cookie, credential, or cache state.
///
/// Cooperative cancellation is preserved throughout: a `CancellationError` from the
/// transport is rethrown unchanged, `Task.checkCancellation()` runs before any other
/// transport error is wrapped (so a `URLError.cancelled` from a cancelled session task
/// surfaces as `CancellationError`), and cancellation is re-checked before a decoded
/// value is returned. No diagnostic ever includes a response body, request header,
/// password, or token.
struct AuthenticationSession: Sendable {
    private let transport: any HTTPTransport
    private let pin: ContractPin

    /// Creates a session backed by a dedicated ephemeral, credential-free transport and
    /// the current contract pin.
    init() {
        transport = URLSessionTransport()
        pin = .current
    }

    /// Creates a session with an injectable transport and pin for testing.
    init(transport: any HTTPTransport, pin: ContractPin = .current) {
        self.transport = transport
        self.pin = pin
    }

    /// Exchanges email/password credentials for an API token via `POST /authenticate`.
    ///
    /// The request is public: it never carries an `Authorization` header.
    ///
    /// - Throws: ``AuthenticationError/unauthorized`` on HTTP 401, or another
    ///   ``AuthenticationError`` for transport, status, encoding, or decoding failures;
    ///   rethrows `CancellationError` when the task is cancelled.
    func authenticate(
        _ credentials: AuthenticationCredentials,
        on profile: ServerProfile
    ) async throws -> AuthToken {
        let url = profile.endpointURL(path: "/authenticate", pin: pin)
        var request = makeRequest(url: url, method: "POST", token: nil)
        try attachJSONBody(credentials, to: &request)
        return try await perform(request, decoding: AuthToken.self)
    }

    /// Creates an account and returns an API token via `POST /register`.
    ///
    /// The request is public: it never carries an `Authorization` header.
    ///
    /// - Throws: an ``AuthenticationError`` for transport, status, encoding, or decoding
    ///   failures; rethrows `CancellationError` when the task is cancelled.
    func register(
        _ details: RegistrationDetails,
        on profile: ServerProfile
    ) async throws -> AuthToken {
        let url = profile.endpointURL(path: "/register", pin: pin)
        var request = makeRequest(url: url, method: "POST", token: nil)
        try attachJSONBody(details, to: &request)
        return try await perform(request, decoding: AuthToken.self)
    }

    /// Returns the authenticated account via `GET /whoami`.
    ///
    /// Sets exactly `Authorization: Token <token>`.
    ///
    /// - Throws: ``AuthenticationError/unauthorized`` on HTTP 401, or another
    ///   ``AuthenticationError`` for transport, status, or decoding failures; rethrows
    ///   `CancellationError` when the task is cancelled.
    func currentUser(on profile: ServerProfile, token: String) async throws -> CurrentUser {
        let url = profile.endpointURL(path: "/whoami", pin: pin)
        let request = makeRequest(url: url, method: "GET", token: token)
        return try await perform(request, decoding: CurrentUser.self)
    }

    // MARK: - Request construction

    /// Builds a request with common headers and an optional bearer token.
    ///
    /// `Authorization` is added only when `token` is non-`nil`. Cookie handling is always
    /// disabled. Callers attach a JSON body separately via ``attachJSONBody(_:to:)``.
    private func makeRequest(url: URL, method: String, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// JSON-encodes `body` into `request` and sets `Content-Type: application/json`.
    ///
    /// - Throws: ``AuthenticationError/requestEncodingFailed`` if encoding fails. No
    ///   detail is carried because the body may contain a password.
    private func attachJSONBody(_ body: some Encodable, to request: inout URLRequest) throws {
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw AuthenticationError.requestEncodingFailed
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    // MARK: - Request execution

    /// Executes `request` and decodes a 2xx body into `Response`, mapping every failure
    /// mode to a typed ``AuthenticationError`` while preserving cancellation.
    private func perform<Response: Decodable>(
        _ request: URLRequest,
        decoding _: Response.Type
    ) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as AuthenticationError {
            throw error
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            // Rethrow as CancellationError when the enclosing task is cancelled so a
            // URLError.cancelled emitted under cancellation is not misreported.
            try Task.checkCancellation()
            throw AuthenticationError.transportFailure(String(describing: error))
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw AuthenticationError.nonHTTPResponse
        }

        switch http.statusCode {
        case 200 ... 299:
            let decoded: Response
            do {
                decoded = try JSONDecoder().decode(Response.self, from: data)
            } catch {
                try Task.checkCancellation()
                throw AuthenticationError.malformedPayload
            }
            try Task.checkCancellation()
            return decoded
        case 401:
            throw AuthenticationError.unauthorized
        default:
            throw AuthenticationError.unexpectedStatus(http.statusCode)
        }
    }
}
