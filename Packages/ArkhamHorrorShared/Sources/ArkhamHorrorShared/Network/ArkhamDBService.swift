import Foundation

struct ArkhamDBDeckList: Sendable, Equatable {
    let decks: [ArkhamDBRemoteDeckSummary]
    let skippedCount: Int
}

/// Authenticated read-side ArkhamDB endpoints. OAuth credentials never leave the server.
struct ArkhamDBService: Sendable {
    private let transport: any HTTPTransport
    private let pin: ContractPin

    init(transport: any HTTPTransport = URLSessionTransport(), pin: ContractPin = .current) {
        self.transport = transport
        self.pin = pin
    }

    func status(on profile: ServerProfile, token: String) async throws -> ArkhamDBLinkStatus {
        try await decode(request("status", on: profile, token: token))
    }

    func startLink(
        on profile: ServerProfile,
        token: String
    ) async throws -> ArkhamDBLinkStartResponse {
        try await decode(request("link/start", method: "POST", on: profile, token: token))
    }

    func completeLink(
        _ completion: ArkhamDBLinkCompletionRequest, on profile: ServerProfile, token: String
    ) async throws {
        var request = request("link/complete", method: "POST", on: profile, token: token)
        try attach(completion, to: &request)
        // A successful HTTP completion consumes the secret. Never retry because of a
        // changed/empty response body; the caller always refreshes authoritative status.
        _ = try await perform(request)
    }

    func unlink(on profile: ServerProfile, token: String) async throws {
        _ = try await perform(request("link", method: "DELETE", on: profile, token: token))
    }

    func listDecks(on profile: ServerProfile, token: String) async throws -> ArkhamDBDeckList {
        let rows: [JSONValue] = try await decode(request("decks", on: profile, token: token))
        var decks: [ArkhamDBRemoteDeckSummary] = []
        for row in rows {
            guard let data = try? ContractJSON.encode(row) else { continue }
            guard let deck = try? ContractJSON.decode(ArkhamDBRemoteDeckSummary.self, from: data)
            else { continue }
            decks.append(deck)
        }
        return ArkhamDBDeckList(decks: decks, skippedCount: rows.count - decks.count)
    }

    func importDeck(
        _ body: ArkhamDBImportRequest, on profile: ServerProfile, token: String
    ) async throws -> Deck {
        var request = request("decks/import", method: "POST", on: profile, token: token)
        try attach(body, to: &request)
        return try await decode(request, deckOperation: true)
    }

    func syncDeck(
        _ id: DeckID, on profile: ServerProfile, token: String, timeout: TimeInterval
    ) async throws -> Deck {
        let segment = id.rawValue.uuidString.lowercased()
        var request = request("decks/\(segment)/sync", method: "POST", on: profile, token: token)
        request.timeoutInterval = timeout
        return try await decode(request, deckOperation: true)
    }

    private func request(
        _ path: String, method: String = "GET", on profile: ServerProfile, token: String
    ) -> URLRequest {
        let url = profile.endpointURL(path: "/arkham/arkhamdb/\(path)", pin: pin)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func attach(_ body: some Encodable, to request: inout URLRequest) throws {
        do {
            request.httpBody = try ContractJSON.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } catch {
            throw DeckServiceError.requestEncodingFailed
        }
    }

    private func decode<Response: Decodable>(
        _ request: URLRequest, deckOperation: Bool = false
    ) async throws -> Response {
        let data = try await perform(request, deckOperation: deckOperation)
        guard let decoded = try? ContractJSON.decode(Response.self, from: data) else {
            throw DeckServiceError.malformedPayload
        }
        return decoded
    }

    private func perform(_ request: URLRequest, deckOperation: Bool = false) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // Transport diagnostics may contain a request body or callback secret.
            throw DeckServiceError.transportFailure("ArkhamDB transport failed")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse
        else { throw DeckServiceError.nonHTTPResponse }
        switch http.statusCode {
        case 200 ... 299: return data
        case 401: throw DeckServiceError.sessionExpired
        default:
            let remote = try? ContractJSON.decode(ArkhamDBError.self, from: data)
            if remote != nil || http.statusCode == 409 {
                throw DeckServiceError.arkhamDB(remote)
            }
            // Unmapped decks use the server's public fetch fallback. Preserve the
            // same operation errors as DeckService, without masking typed link errors.
            if deckOperation {
                if http.statusCode == 400 {
                    guard let error = try? ContractJSON.decode(DeckOperationError.self, from: data)
                    else { throw DeckServiceError.malformedPayload }
                    throw DeckServiceError.operationFailed(error)
                }
                if (500 ... 599).contains(http.statusCode) {
                    throw DeckServiceError.remoteDeckSourceUnavailable
                }
            }
            if http.statusCode == 501 {
                throw DeckServiceError.arkhamDB(nil)
            }
            if http.statusCode == 400 {
                if let errors = try? ContractJSON.decode(DeckValidationErrors.self, from: data) {
                    throw DeckServiceError.validationFailed(errors)
                }
            }
            throw DeckServiceError.unexpectedStatus(http.statusCode)
        }
    }
}
