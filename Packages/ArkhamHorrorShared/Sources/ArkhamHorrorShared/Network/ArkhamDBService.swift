import Foundation

struct ArkhamDBDeckList: Sendable, Equatable {
    let decks: [ArkhamDBRemoteDeckSummary]
    let skippedCount: Int
}

/// Authenticated read-side ArkhamDB endpoints. OAuth credentials never leave the server.
///
/// Every request is sent through one `ArkhamDBRequestGate`, shared by all copies of a
/// service, so at most one is in flight at a time.
struct ArkhamDBService: Sendable {
    private let transport: any HTTPTransport
    private let pin: ContractPin
    let gate: ArkhamDBRequestGate

    /// Runs after a request is admitted by the gate and before it is sent. A request can
    /// wait behind others, so callers bind their session check here; a throw sends
    /// nothing and is rethrown unchanged. Task-locals are inherited by child and
    /// unstructured tasks, so every gated caller must bind its own check (or nil) rather
    /// than run under one bound by whoever started it.
    @TaskLocal static var sendCheck: (@Sendable () async throws -> Void)?

    init(
        transport: any HTTPTransport = URLSessionTransport(),
        pin: ContractPin = .current,
        gate: ArkhamDBRequestGate = ArkhamDBRequestGate()
    ) {
        self.transport = transport
        self.pin = pin
        self.gate = gate
    }

    /// A `.background` status request never waits: it throws `ArkhamDBRequestGate.Busy`
    /// without sending while another request is in flight or waiting.
    func status(
        on profile: ServerProfile,
        token: String,
        priority: ArkhamDBRequestGate.Priority = .user
    ) async throws -> ArkhamDBLinkStatus {
        try await decode(request("status", on: profile, token: token), priority: priority)
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
        return try await decode(request, context: .deckOperation)
    }

    func syncDeck(
        _ id: DeckID, on profile: ServerProfile, token: String, timeout: TimeInterval
    ) async throws -> Deck {
        let segment = id.rawValue.uuidString.lowercased()
        var request = request("decks/\(segment)/sync", method: "POST", on: profile, token: token)
        request.timeoutInterval = timeout
        return try await decode(request, context: .deckOperation)
    }

    /// Opts an owned linked deck in or out. Returns every owned deck's write-back status.
    func setWriteBack(
        deckID: DeckID, enabled: Bool, on profile: ServerProfile, token: String
    ) async throws -> [ArkhamDBWriteBackStatus] {
        var request = writeBackRequest(deckID, "write-back", method: "PUT", profile, token)
        try attach(ArkhamDBWriteBackToggleRequest(enabled: enabled), to: &request)
        return try await decode(request, context: .writeBack)
    }

    /// Asynchronously retries the oldest pending or failed push; poll status afterwards.
    func retryWriteBack(
        deckID: DeckID, on profile: ServerProfile, token: String
    ) async throws -> [ArkhamDBWriteBackStatus] {
        let request = writeBackRequest(deckID, "write-back/retry", method: "POST", profile, token)
        return try await decode(request, context: .writeBack)
    }

    /// Resolves a conflict. Overwrite and save-as-new throw
    /// `ArkhamDBResolveConflictRequest.ValidationError.confirmationRequired` before any
    /// request unless `confirmed` is true.
    func resolveConflict(
        deckID: DeckID,
        resolution: ArkhamDBWriteBackResolution,
        confirmed: Bool,
        on profile: ServerProfile,
        token: String
    ) async throws -> [ArkhamDBWriteBackStatus] {
        let body = try ArkhamDBResolveConflictRequest(resolution: resolution, confirmed: confirmed)
        var request = writeBackRequest(deckID, "resolve-conflict", method: "POST", profile, token)
        try attach(body, to: &request)
        return try await decode(request, context: .writeBack)
    }

    private func writeBackRequest(
        _ id: DeckID, _ suffix: String, method: String, _ profile: ServerProfile, _ token: String
    ) -> URLRequest {
        let segment = id.rawValue.uuidString.lowercased()
        return request("decks/\(segment)/\(suffix)", method: method, on: profile, token: token)
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

    /// Selects how non-2xx responses without a typed ArkhamDB body are classified.
    private enum ErrorContext {
        case account
        case deckOperation
        case writeBack
    }

    private func decode<Response: Decodable>(
        _ request: URLRequest,
        context: ErrorContext = .account,
        priority: ArkhamDBRequestGate.Priority = .user
    ) async throws -> Response {
        let data = try await perform(request, context: context, priority: priority)
        guard let decoded = try? ContractJSON.decode(Response.self, from: data) else {
            throw DeckServiceError.malformedPayload
        }
        return decoded
    }

    private func perform(
        _ request: URLRequest,
        context: ErrorContext = .account,
        priority: ArkhamDBRequestGate.Priority = .user
    ) async throws -> Data {
        let sent = try await send(request, priority: priority)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try sent.get()
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
            throw responseError(data, statusCode: http.statusCode, context: context)
        }
    }

    /// Holds the gate only around the transport call. Admission failures (`Busy`,
    /// cancellation, a failed `sendCheck`) throw before sending; transport outcomes are
    /// returned so the permit is released on every path before they are classified.
    private func send(
        _ request: URLRequest, priority: ArkhamDBRequestGate.Priority
    ) async throws -> Result<(Data, URLResponse), any Error> {
        try await gate.acquire(priority)
        do {
            try Task.checkCancellation()
            try await Self.sendCheck?()
        } catch {
            await gate.release()
            throw error
        }
        let sent: Result<(Data, URLResponse), any Error>
        do {
            sent = try await .success(transport.data(for: request))
        } catch {
            sent = .failure(error)
        }
        await gate.release()
        return sent
    }

    private func responseError(
        _ data: Data, statusCode: Int, context: ErrorContext
    ) -> DeckServiceError {
        let remote = try? ContractJSON.decode(ArkhamDBError.self, from: data)
        if remote != nil || statusCode == 409 {
            return .arkhamDB(remote)
        }
        switch context {
        case .account:
            break
        case .deckOperation:
            return deckOperationError(data, statusCode: statusCode)
        case .writeBack:
            if let error = writeBackError(statusCode) {
                return .arkhamDB(error)
            }
        }
        if statusCode == 501 {
            return .arkhamDB(nil)
        }
        if statusCode == 400 {
            if let errors = try? ContractJSON.decode(DeckValidationErrors.self, from: data) {
                return .validationFailed(errors)
            }
        }
        return .unexpectedStatus(statusCode)
    }

    /// The server answers write-back 400/404 with framework bodies, not ArkhamDB errors.
    /// Type them with the server's own status pairing (validationFailed→400,
    /// notFound→404) so callers never treat them as session expiry or relinking.
    private func writeBackError(_ statusCode: Int) -> ArkhamDBError? {
        switch statusCode {
        case 400:
            ArkhamDBError(
                code: .validationFailed,
                error: "ArkhamDB write-back request was rejected"
            )
        case 404:
            ArkhamDBError(code: .notFound, error: "ArkhamDB deck link was not found")
        default:
            nil
        }
    }

    private func deckOperationError(_ data: Data, statusCode: Int) -> DeckServiceError {
        // Unmapped decks use the server's public fetch fallback. Preserve the
        // same operation errors as DeckService, without masking typed link errors.
        switch statusCode {
        case 400:
            if let error = try? ContractJSON.decode(DeckOperationError.self, from: data) {
                return .operationFailed(error)
            }
            if let errors = try? ContractJSON.decode(DeckValidationErrors.self, from: data) {
                return .validationFailed(errors)
            }
            return .malformedPayload
        case 500 ... 599:
            return .remoteDeckSourceUnavailable
        default:
            return .unexpectedStatus(statusCode)
        }
    }
}
