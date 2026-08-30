import Foundation

/// A typed, authenticated HTTP client for the game-lifecycle/lobby endpoints, over an
/// injectable ``HTTPTransport``.
///
/// Endpoint URLs are derived from the selected ``ServerProfile`` and the injected
/// ``ContractPin`` -- the same pin ``CapabilityProbe`` and ``AuthenticationSession``
/// use -- so this client never targets a hard-coded host. Every request sets
/// `Accept: application/json`, disables cookie handling, and sets exactly
/// `Authorization: Token <token>`; every operation here is authenticated (there is no
/// public game-lifecycle endpoint).
///
/// Every request/response body is encoded/decoded exclusively through ``ContractJSON``,
/// never a stock `JSONEncoder`/`JSONDecoder`, including the deliberately shallow
/// ``GameLifecycleEnvelope`` decode of the full `PublicGame` body `create`/`join`
/// return (this client never decodes board state; see that type's documentation).
/// `DELETE`/`claim-seat`/`decks` never touch a JSON decoder at all: every one of
/// those handlers has a Yesod `Handler ()` return type, whose `ToTypedContent ()`
/// instance (`toTypedContent () = TypedContent typePlain (toContent ())`,
/// `toContent () = toContent B.empty`) always sends a genuine zero-byte body with
/// `Content-Type: text/plain` on success -- never a JSON `"[]"` array or any other
/// shape -- exactly matching the governed OpenAPI spec's `200` responses for these
/// three operations, each of which declares no `content:` schema at all. See
/// ``performNoContent(_:)``.
///
/// A `GameID` path segment is independently percent-encoded (unreserved ASCII
/// characters only) before being embedded into the URL via `percentEncodedPath`,
/// which never re-interprets an already-escaped `%`. A literal `/`, `.`, or non-ASCII
/// byte in that segment therefore can never introduce, remove, or reinterpret a path
/// separator -- route structure cannot be altered by any identifier this client sends,
/// even though every ``GameID`` this client actually constructs is already a `UUID`
/// that requires no escaping at all.
///
/// The default transport is a dedicated ephemeral ``URLSessionTransport`` that draws
/// from no shared cookie, credential, or cache state; TLS validation is never bypassed
/// and redirects are always rejected (see ``URLSessionTransport``).
///
/// Cooperative cancellation is preserved throughout, mirroring ``AuthenticationSession``:
/// a `CancellationError` from the transport is rethrown unchanged,
/// `Task.checkCancellation()` runs before any other transport error is wrapped, and
/// cancellation is re-checked before a decoded value is returned. No diagnostic ever
/// includes a response body, request header, or token.
struct GameLifecycleService: Sendable {
    private let transport: any HTTPTransport
    private let pin: ContractPin

    /// Only unreserved RFC 3986 characters (ASCII letters, digits, `-`, `_`, `~`) pass
    /// through unescaped. Deliberately narrower than `CharacterSet.alphanumerics`
    /// (which admits non-ASCII Unicode letters/digits) and deliberately excludes `.`
    /// (unlike the RFC's own unreserved set) so a segment that happens to be exactly
    /// `.` or `..` can never be embedded as a literal dot-segment.
    private static let unreservedPathCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~"
    )

    /// Creates a service backed by a dedicated ephemeral, credential-free transport and
    /// the current contract pin.
    init() {
        transport = URLSessionTransport()
        pin = .current
    }

    /// Creates a service with an injectable transport and pin for testing.
    init(transport: any HTTPTransport, pin: ContractPin = .current) {
        self.transport = transport
        self.pin = pin
    }

    // MARK: - Games

    func listGames(on profile: ServerProfile, token: String) async throws -> GameList {
        let url = profile.endpointURL(path: "/arkham/games", pin: pin)
        let request = makeRequest(url: url, method: "GET", token: token)
        return try await perform(request, decoding: GameList.self)
    }

    func createGame(
        _ request: CreateGameRequest, on profile: ServerProfile, token: String
    ) async throws -> GameLifecycleEnvelope {
        let url = profile.endpointURL(path: "/arkham/games", pin: pin)
        var urlRequest = makeRequest(url: url, method: "POST", token: token)
        try attachJSONBody(request, to: &urlRequest)
        return try await perform(urlRequest, decoding: GameLifecycleEnvelope.self)
    }

    func deleteGame(_ id: GameID, on profile: ServerProfile, token: String) async throws {
        let url = try gameURL(id, on: profile)
        let request = makeRequest(url: url, method: "DELETE", token: token)
        try await performNoContent(request)
    }

    // MARK: - Lobby

    func peekLobby(
        _ id: GameID, on profile: ServerProfile, token: String
    ) async throws -> GameLifecycleEnvelope {
        let url = try gameURL(id, suffix: "/join", on: profile)
        let request = makeRequest(url: url, method: "GET", token: token)
        return try await perform(request, decoding: GameLifecycleEnvelope.self)
    }

    func joinGame(
        _ id: GameID, on profile: ServerProfile, token: String
    ) async throws -> GameLifecycleEnvelope {
        let url = try gameURL(id, suffix: "/join", on: profile)
        let request = makeRequest(url: url, method: "PUT", token: token)
        return try await perform(request, decoding: GameLifecycleEnvelope.self)
    }

    func openSeats(
        for id: GameID, on profile: ServerProfile, token: String
    ) async throws -> OpenSeats {
        let url = try gameURL(id, suffix: "/open-seats", on: profile)
        let request = makeRequest(url: url, method: "GET", token: token)
        return try await perform(request, decoding: OpenSeats.self)
    }

    func claimSeat(
        _ request: ClaimSeatRequest, in id: GameID, on profile: ServerProfile, token: String
    ) async throws {
        let url = try gameURL(id, suffix: "/claim-seat", on: profile)
        var urlRequest = makeRequest(url: url, method: "POST", token: token)
        try attachJSONBody(request, to: &urlRequest)
        try await performNoContent(urlRequest)
    }

    func chooseDeck(
        _ request: ChooseDeckRequest, in id: GameID, on profile: ServerProfile, token: String
    ) async throws {
        let url = try gameURL(id, suffix: "/decks", on: profile)
        var urlRequest = makeRequest(url: url, method: "PUT", token: token)
        try attachJSONBody(request, to: &urlRequest)
        try await performNoContent(urlRequest)
    }

    // MARK: - URL construction

    /// Percent-encodes a raw path-segment string using only
    /// ``unreservedPathCharacters``, so a literal `/`, `.`, `%`, `?`, `#`, or
    /// non-ASCII byte is always escaped rather than passed through as live path
    /// structure. Not `private` so a direct unit test can exercise this exact
    /// encoding against adversarial strings a real ``GameID`` (always a `UUID`) can
    /// never actually contain.
    static func percentEncodedGameIDSegment(_ raw: String) -> String? {
        raw.addingPercentEncoding(withAllowedCharacters: unreservedPathCharacters)
    }

    /// Builds `<profile>/arkham/games/<id>[<suffix>]`, independently percent-encoding
    /// `id`'s wire text (see ``percentEncodedGameIDSegment(_:)``) and appending it via
    /// `percentEncodedPath`, which treats the base path's own encoding and this
    /// segment's encoding as already-final and never re-escapes either.
    private func gameURL(
        _ id: GameID, suffix: String = "", on profile: ServerProfile
    ) throws -> URL {
        let base = profile.endpointURL(path: "/arkham/games", pin: pin)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw GameLifecycleError.invalidPathSegment
        }
        guard let segment = Self.percentEncodedGameIDSegment(id.description) else {
            throw GameLifecycleError.invalidPathSegment
        }
        components.percentEncodedPath += "/\(segment)\(suffix)"
        guard let url = components.url else {
            throw GameLifecycleError.invalidPathSegment
        }
        return url
    }

    // MARK: - Request construction

    /// Builds a request with common headers and a required bearer token. Cookie
    /// handling is always disabled. Callers attach a JSON body separately via
    /// ``attachJSONBody(_:to:)``.
    private func makeRequest(url: URL, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Encodes `body` into `request` through ``ContractJSON`` (never a stock
    /// `JSONEncoder`) and sets `Content-Type: application/json`.
    ///
    /// - Throws: ``GameLifecycleError/requestEncodingFailed`` if encoding fails.
    private func attachJSONBody(_ body: some Encodable, to request: inout URLRequest) throws {
        do {
            request.httpBody = try ContractJSON.encode(body)
        } catch {
            throw GameLifecycleError.requestEncodingFailed
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    // MARK: - Request execution

    /// Executes `request`, mapping every failure mode to a typed ``GameLifecycleError``
    /// while preserving cancellation, and returns the raw 2xx response body
    /// undecoded. Shared by ``perform(_:decoding:)`` (which decodes the returned bytes
    /// through ``ContractJSON``) and ``performNoContent(_:)`` (which asserts the bytes
    /// are empty and never invokes any JSON decoder on them at all) so both share
    /// identical transport/cancellation/status-mapping behavior.
    private func performRaw(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as GameLifecycleError {
            throw error
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            // Rethrow as CancellationError when the enclosing task is cancelled so a
            // URLError.cancelled emitted under cancellation is not misreported.
            try Task.checkCancellation()
            throw GameLifecycleError.transportFailure(String(describing: error))
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw GameLifecycleError.nonHTTPResponse
        }

        switch http.statusCode {
        case 200 ... 299:
            return data
        case 401:
            throw GameLifecycleError.sessionExpired
        default:
            throw GameLifecycleError.unexpectedStatus(http.statusCode)
        }
    }

    /// Executes `request` and decodes a 2xx body into `Response` through
    /// ``ContractJSON``.
    private func perform<Response: Decodable>(
        _ request: URLRequest,
        decoding _: Response.Type
    ) async throws -> Response {
        let data = try await performRaw(request)
        let decoded: Response
        do {
            decoded = try ContractJSON.decode(Response.self, from: data)
        } catch {
            try Task.checkCancellation()
            throw GameLifecycleError.malformedPayload
        }
        try Task.checkCancellation()
        return decoded
    }

    /// Executes `request` for an endpoint documented (both in the governed OpenAPI
    /// spec and in the production Yesod `Handler ()` source backing it) to return no
    /// response body on success, asserting the 2xx body is exactly empty rather than
    /// running it through any JSON decoder. A non-empty 2xx body is reported as
    /// ``GameLifecycleError/malformedPayload`` so contract drift (the server
    /// unexpectedly starting to send a body) remains visible instead of being
    /// silently ignored.
    private func performNoContent(_ request: URLRequest) async throws {
        let data = try await performRaw(request)
        guard data.isEmpty else {
            try Task.checkCancellation()
            throw GameLifecycleError.malformedPayload
        }
        try Task.checkCancellation()
    }
}
