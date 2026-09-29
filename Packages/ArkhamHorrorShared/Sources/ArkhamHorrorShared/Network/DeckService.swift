import Foundation

/// A typed, authenticated HTTP client for saved-deck endpoints.
///
/// This mirrors ``GameLifecycleService``'s transport and JSON boundaries: endpoint URLs
/// are derived from the selected ``ServerProfile`` and ``ContractPin``, requests set
/// `Accept: application/json` and `Authorization: Token <token>`, and request/response
/// bodies are encoded and decoded exclusively through ``ContractJSON``.
struct DeckService: Sendable {
    private let transport: any HTTPTransport
    private let pin: ContractPin

    init() {
        transport = URLSessionTransport()
        pin = .current
    }

    init(transport: any HTTPTransport, pin: ContractPin = .current) {
        self.transport = transport
        self.pin = pin
    }

    func listDecks(on profile: ServerProfile, token: String) async throws -> DeckListResponse {
        let url = profile.endpointURL(path: "/arkham/decks", pin: pin)
        let request = makeRequest(url: url, method: "GET", token: token)
        return try await perform(request, decoding: DeckListResponse.self)
    }

    func fetchDeckList(
        _ request: FetchDeckRequest, on profile: ServerProfile, token: String
    ) async throws -> DeckList {
        let url = profile.endpointURL(path: "/arkham/decks/fetch", pin: pin)
        var urlRequest = makeRequest(url: url, method: "POST", token: token)
        try attachJSONBody(request, to: &urlRequest)
        return try await perform(
            urlRequest,
            decoding: DeckList.self,
            badRequest: .operation
        )
    }

    func createDeck(
        _ request: CreateDeckRequest, on profile: ServerProfile, token: String
    ) async throws -> Deck {
        let url = profile.endpointURL(path: "/arkham/decks", pin: pin)
        var urlRequest = makeRequest(url: url, method: "POST", token: token)
        try attachJSONBody(request, to: &urlRequest)
        return try await perform(
            urlRequest,
            decoding: Deck.self,
            badRequest: .validation
        )
    }

    /// Imports an ArkhamDB-style deck exactly as the web client does: fetch/normalize the
    /// external URL first, then save the returned deck list with the deck's external id,
    /// name, and URL preserved when present.
    func importDeck(
        from url: String, on profile: ServerProfile, token: String
    ) async throws -> Deck {
        let deckList = try await fetchDeckList(
            FetchDeckRequest(url: url), on: profile, token: token
        )
        let request = CreateDeckRequest(
            deckId: deckList.id ?? url,
            deckName: deckList.name ?? deckList.investigatorName,
            deckUrl: deckList.url ?? url,
            deckList: DeckListInput(deckList)
        )
        return try await createDeck(request, on: profile, token: token)
    }

    func deleteDeck(_ id: DeckID, on profile: ServerProfile, token: String) async throws {
        let url = try deckURL(id, on: profile)
        let request = makeRequest(url: url, method: "DELETE", token: token)
        try await performNoContent(request)
    }

    func validateDeckList(
        _ deckList: DeckListInput, on profile: ServerProfile, token: String
    ) async throws -> DeckValidationSuccess {
        let url = profile.endpointURL(path: "/arkham/decks/validate", pin: pin)
        var request = makeRequest(url: url, method: "POST", token: token)
        try attachJSONBody(deckList, to: &request)
        return try await perform(
            request,
            decoding: DeckValidationSuccess.self,
            badRequest: .validation
        )
    }

    // MARK: - URL construction

    private static let unreservedPathCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~"
    )

    static func percentEncodedDeckIDSegment(_ raw: String) -> String? {
        raw.addingPercentEncoding(withAllowedCharacters: unreservedPathCharacters)
    }

    static func deckURL(
        _ id: DeckID, on profile: ServerProfile, pin: ContractPin
    ) throws -> URL {
        let base = profile.endpointURL(path: "/arkham/decks", pin: pin)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw DeckServiceError.invalidPathSegment
        }
        guard let segment = percentEncodedDeckIDSegment(id.rawValue.uuidString.lowercased()) else {
            throw DeckServiceError.invalidPathSegment
        }
        components.percentEncodedPath += "/\(segment)"
        guard let url = components.url else {
            throw DeckServiceError.invalidPathSegment
        }
        return url
    }

    private func deckURL(_ id: DeckID, on profile: ServerProfile) throws -> URL {
        try Self.deckURL(id, on: profile, pin: pin)
    }

    // MARK: - Request construction

    private func makeRequest(url: URL, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func attachJSONBody(_ body: some Encodable, to request: inout URLRequest) throws {
        do {
            request.httpBody = try ContractJSON.encode(body)
        } catch {
            throw DeckServiceError.requestEncodingFailed
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    // MARK: - Request execution

    private enum BadRequestDecoder {
        case generic
        case operation
        case validation
    }

    private func performRaw(
        _ request: URLRequest, badRequest: BadRequestDecoder
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as DeckServiceError {
            throw error
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            try Task.checkCancellation()
            throw DeckServiceError.transportFailure(String(describing: error))
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw DeckServiceError.nonHTTPResponse
        }

        switch http.statusCode {
        case 200 ... 299:
            return data
        case 400:
            throw decodeBadRequest(data, as: badRequest)
        case 401:
            throw DeckServiceError.sessionExpired
        default:
            throw DeckServiceError.unexpectedStatus(http.statusCode)
        }
    }

    private func decodeBadRequest(_ data: Data, as decoder: BadRequestDecoder) -> DeckServiceError {
        switch decoder {
        case .generic:
            return .unexpectedStatus(400)
        case .operation:
            if let error = try? ContractJSON.decode(DeckOperationError.self, from: data) {
                return .operationFailed(error)
            }
            return .malformedPayload
        case .validation:
            if let errors = try? ContractJSON.decode(DeckValidationErrors.self, from: data) {
                return .validationFailed(errors)
            }
            return .malformedPayload
        }
    }

    private func perform<Response: Decodable>(
        _ request: URLRequest,
        decoding _: Response.Type,
        badRequest: BadRequestDecoder = .generic
    ) async throws -> Response {
        let data = try await performRaw(request, badRequest: badRequest)
        let decoded: Response
        do {
            decoded = try ContractJSON.decode(Response.self, from: data)
        } catch {
            try Task.checkCancellation()
            throw DeckServiceError.malformedPayload
        }
        try Task.checkCancellation()
        return decoded
    }

    private func performNoContent(_ request: URLRequest) async throws {
        let data = try await performRaw(request, badRequest: .generic)
        guard data.isEmpty else {
            try Task.checkCancellation()
            throw DeckServiceError.malformedPayload
        }
        try Task.checkCancellation()
    }
}

enum DeckServiceError: Error, Equatable, Sendable {
    case invalidPathSegment
    case requestEncodingFailed
    case transportFailure(String)
    case nonHTTPResponse
    case sessionExpired
    case unexpectedStatus(Int)
    case malformedPayload
    case operationFailed(DeckOperationError)
    case validationFailed(DeckValidationErrors)
}

extension DeckServiceError {
    var message: String {
        switch self {
        case .invalidPathSegment:
            "The deck identifier could not be sent safely."
        case .requestEncodingFailed:
            "The deck request could not be encoded."
        case .transportFailure:
            "The server could not be reached. Check your connection and try again."
        case .nonHTTPResponse:
            "The server returned an unsupported response."
        case .sessionExpired:
            "Your session expired. Sign in again to manage decks."
        case let .unexpectedStatus(status):
            "The server returned an unexpected deck response (HTTP \(status))."
        case .malformedPayload:
            "The server returned deck data this app could not read."
        case let .operationFailed(error):
            error.errorMsg
        case let .validationFailed(errors):
            Self.validationMessage(errors)
        }
    }

    private static func validationMessage(_ errors: DeckValidationErrors) -> String {
        let details = errors.elements.map { error in
            switch error {
            case let .unimplementedCard(cardCode):
                "Unsupported card \(cardCode.rawValue)"
            case .unsupported:
                "Unsupported deck validation error"
            }
        }
        return details.joined(separator: ", ")
    }
}
