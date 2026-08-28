@testable import ArkhamHorrorShared
import Foundation
import Testing

// MARK: - Test doubles

/// Records the last request and returns a canned response.
private actor RecordingTransport: HTTPTransport {
    private(set) var capturedRequest: URLRequest?
    private let stubData: Data
    private let stubResponse: URLResponse

    init(data: Data, response: URLResponse) {
        stubData = data
        stubResponse = response
    }

    nonisolated func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await record(request)
        return (stubData, stubResponse)
    }

    private func record(_ request: URLRequest) {
        capturedRequest = request
    }
}

private struct FailingTransport: HTTPTransport {
    let error: any Error & Sendable
    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        throw error
    }
}

private struct TransportFailure: Error, Sendable {}

private typealias GateContinuation = CheckedContinuation<(Data, URLResponse), any Error>

/// Blocks `data(for:)` until the caller releases the gate, so a task is guaranteed
/// mid-flight before cancellation is injected.
private actor GatedTransport: HTTPTransport {
    private var pendingGate: GateContinuation?
    private var gateWaiter: CheckedContinuation<GateContinuation, Never>?

    func awaitGate() async -> GateContinuation {
        if let gate = pendingGate {
            pendingGate = nil
            return gate
        }
        return await withCheckedContinuation { gateWaiter = $0 }
    }

    private func deliverGate(_ gate: GateContinuation) {
        if let waiter = gateWaiter {
            waiter.resume(returning: gate)
            gateWaiter = nil
        } else {
            pendingGate = gate
        }
    }

    nonisolated func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { gate in
            Task { await self.deliverGate(gate) }
        }
    }
}

// MARK: - Tests

@Suite("AuthenticationSession")
struct AuthenticationSessionTests {
    private let profile = ServerProfile.hosted
    private let credentials = AuthenticationCredentials(email: "a@example.com", password: "pw")
    private let registration = RegistrationDetails(
        email: "a@example.com",
        username: "ashcan",
        password: "pw"
    )

    private func httpResponse(_ status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func tokenBody() -> Data {
        Data(#"{"token":"issued-token"}"#.utf8)
    }

    // MARK: - authenticate request shaping

    @Test("authenticate issues a POST to the pin-derived /authenticate URL")
    func authenticateRequestURLAndMethod() async throws {
        let url = profile.endpointURL(path: "/authenticate")
        let transport = RecordingTransport(data: tokenBody(), response: httpResponse(200, url: url))
        let session = AuthenticationSession(transport: transport)
        _ = try await session.authenticate(credentials, on: profile)
        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "POST")
        #expect(request?.url?.absoluteString == "https://arkhamhorror.app/api/v1/authenticate")
    }

    @Test("authenticate sets JSON headers, disables cookies, and sends no Authorization")
    func authenticateRequestHeaders() async throws {
        let url = profile.endpointURL(path: "/authenticate")
        let transport = RecordingTransport(data: tokenBody(), response: httpResponse(200, url: url))
        let session = AuthenticationSession(transport: transport)
        _ = try await session.authenticate(credentials, on: profile)
        let request = await transport.capturedRequest
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request?.httpShouldHandleCookies == false)
    }

    @Test("authenticate encodes the credentials as the JSON body")
    func authenticateRequestBody() async throws {
        let url = profile.endpointURL(path: "/authenticate")
        let transport = RecordingTransport(data: tokenBody(), response: httpResponse(200, url: url))
        let session = AuthenticationSession(transport: transport)
        _ = try await session.authenticate(credentials, on: profile)
        let body = try #require(await transport.capturedRequest?.httpBody)
        let decoded = try JSONDecoder().decode(AuthenticationCredentials.self, from: body)
        #expect(decoded == credentials)
    }

    @Test("authenticate returns the decoded token on success")
    func authenticateSuccess() async throws {
        let url = profile.endpointURL(path: "/authenticate")
        let transport = RecordingTransport(data: tokenBody(), response: httpResponse(200, url: url))
        let session = AuthenticationSession(transport: transport)
        let token = try await session.authenticate(credentials, on: profile)
        #expect(token == AuthToken(token: "issued-token"))
    }

    // MARK: - register request shaping

    @Test("register issues a POST to /register with body and no Authorization")
    func registerRequest() async throws {
        let url = profile.endpointURL(path: "/register")
        let transport = RecordingTransport(data: tokenBody(), response: httpResponse(200, url: url))
        let session = AuthenticationSession(transport: transport)
        _ = try await session.register(registration, on: profile)
        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "POST")
        #expect(request?.url?.absoluteString == "https://arkhamhorror.app/api/v1/register")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(request?.httpBody)
        #expect(try JSONDecoder().decode(RegistrationDetails.self, from: body) == registration)
    }

    // MARK: - whoami request shaping

    @Test("currentUser issues a GET to /whoami with Authorization: Token and no body")
    func whoamiRequest() async throws {
        let url = profile.endpointURL(path: "/whoami")
        let body = Data(#"{"username":"u","email":"u@example.com","beta":false,"admin":true}"#.utf8)
        let transport = RecordingTransport(data: body, response: httpResponse(200, url: url))
        let session = AuthenticationSession(transport: transport)
        _ = try await session.currentUser(on: profile, token: "abc")
        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "GET")
        #expect(request?.url?.absoluteString == "https://arkhamhorror.app/api/v1/whoami")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Token abc")
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request?.httpBody == nil)
        #expect(request?.httpShouldHandleCookies == false)
    }

    @Test("currentUser returns the decoded account on success")
    func whoamiSuccess() async throws {
        let url = profile.endpointURL(path: "/whoami")
        let body = Data(#"{"username":"u","email":"u@example.com","beta":false,"admin":true}"#.utf8)
        let transport = RecordingTransport(data: body, response: httpResponse(200, url: url))
        let session = AuthenticationSession(transport: transport)
        let user = try await session.currentUser(on: profile, token: "abc")
        #expect(user == CurrentUser(
            username: "u",
            email: "u@example.com",
            beta: false,
            admin: true
        ))
    }

    // MARK: - Custom profile & injected pin

    @Test("authenticate targets a custom server's port and path prefix")
    func customProfileURL() async throws {
        let custom = try ServerProfile.custom(
            displayName: "Self-hosted",
            rawURL: "http://localhost:9000/myapp"
        )
        let url = custom.endpointURL(path: "/authenticate")
        let transport = RecordingTransport(data: tokenBody(), response: httpResponse(200, url: url))
        let session = AuthenticationSession(transport: transport)
        _ = try await session.authenticate(credentials, on: custom)
        let request = await transport.capturedRequest
        #expect(
            request?.url?.absoluteString == "http://localhost:9000/myapp/api/v1/authenticate"
        )
    }

    @Test("An injected pin determines the request base path")
    func injectedPinURL() async throws {
        let pin = ContractPin(
            backendCommit: "test",
            supportedSchemaRevision: .literal(major: 0, minor: 1, patch: 11),
            minimumServerSchemaRevision: .literal(major: 0, minor: 1, patch: 11),
            expectedApiBasePath: "/api/v2",
            sourceNativeClientMinimumRevision: .literal(major: 0, minor: 1, patch: 0)
        )
        let url = profile.endpointURL(path: "/authenticate", pin: pin)
        let transport = RecordingTransport(data: tokenBody(), response: httpResponse(200, url: url))
        let session = AuthenticationSession(transport: transport, pin: pin)
        _ = try await session.authenticate(credentials, on: profile)
        let request = await transport.capturedRequest
        #expect(request?.url?.absoluteString == "https://arkhamhorror.app/api/v2/authenticate")
    }

    // MARK: - Error mapping

    @Test("HTTP 401 on authenticate maps to unauthorized")
    func authenticateUnauthorized() async {
        let url = profile.endpointURL(path: "/authenticate")
        let transport = RecordingTransport(data: Data(), response: httpResponse(401, url: url))
        let session = AuthenticationSession(transport: transport)
        await #expect(throws: AuthenticationError.unauthorized) {
            try await session.authenticate(credentials, on: profile)
        }
    }

    @Test("HTTP 401 on whoami maps to unauthorized")
    func whoamiUnauthorized() async {
        let url = profile.endpointURL(path: "/whoami")
        let transport = RecordingTransport(data: Data(), response: httpResponse(401, url: url))
        let session = AuthenticationSession(transport: transport)
        await #expect(throws: AuthenticationError.unauthorized) {
            try await session.currentUser(on: profile, token: "abc")
        }
    }

    @Test("An unexpected status maps to unexpectedStatus")
    func unexpectedStatus() async {
        let url = profile.endpointURL(path: "/authenticate")
        let transport = RecordingTransport(data: Data(), response: httpResponse(500, url: url))
        let session = AuthenticationSession(transport: transport)
        await #expect(throws: AuthenticationError.unexpectedStatus(500)) {
            try await session.authenticate(credentials, on: profile)
        }
    }

    @Test("A malformed 2xx body maps to malformedPayload")
    func malformedPayload() async {
        let url = profile.endpointURL(path: "/authenticate")
        let transport = RecordingTransport(
            data: Data("not json".utf8),
            response: httpResponse(200, url: url)
        )
        let session = AuthenticationSession(transport: transport)
        await #expect(throws: AuthenticationError.malformedPayload) {
            try await session.authenticate(credentials, on: profile)
        }
    }

    @Test("A non-HTTP response maps to nonHTTPResponse")
    func nonHTTPResponse() async {
        let url = profile.endpointURL(path: "/authenticate")
        let response = URLResponse(
            url: url,
            mimeType: nil,
            expectedContentLength: 0,
            textEncodingName: nil
        )
        let transport = RecordingTransport(data: tokenBody(), response: response)
        let session = AuthenticationSession(transport: transport)
        await #expect(throws: AuthenticationError.nonHTTPResponse) {
            try await session.authenticate(credentials, on: profile)
        }
    }

    @Test("A transport-level failure maps to transportFailure")
    func transportFailurePropagates() async {
        let session = AuthenticationSession(transport: FailingTransport(error: TransportFailure()))
        await #expect(throws: AuthenticationError.transportFailure("")) {
            try await session.authenticate(credentials, on: profile)
        }
    }

    // MARK: - Cancellation

    @Test("A transport-thrown CancellationError is not wrapped")
    func cancellationNotWrapped() async {
        let session = AuthenticationSession(transport: FailingTransport(error: CancellationError()))
        await #expect(throws: CancellationError.self) {
            try await session.authenticate(credentials, on: profile)
        }
    }

    @Test("URLError.cancelled from a cancelled task surfaces as CancellationError")
    func urlErrorCancelledSurfacesAsCancellation() async {
        let transport = GatedTransport()
        let session = AuthenticationSession(transport: transport)
        let task = Task<AuthToken, any Error> {
            try await session.authenticate(credentials, on: profile)
        }
        let gate = await transport.awaitGate()
        task.cancel()
        gate.resume(throwing: URLError(.cancelled))
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError but got: \(error)")
        }
    }

    @Test("A cancelled task cannot return a successful result")
    func cancelledTaskCannotReturnSuccess() async {
        let url = profile.endpointURL(path: "/authenticate")
        let transport = GatedTransport()
        let session = AuthenticationSession(transport: transport)
        let task = Task<AuthToken, any Error> {
            try await session.authenticate(credentials, on: profile)
        }
        let gate = await transport.awaitGate()
        task.cancel()
        gate.resume(returning: (tokenBody(), httpResponse(200, url: url)))
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    // MARK: - No secret leakage

    @Test("Errors never contain the credential password")
    func errorsDoNotLeakPassword() async {
        let secret = "very-secret-password"
        let creds = AuthenticationCredentials(email: "a@example.com", password: secret)
        let url = profile.endpointURL(path: "/authenticate")
        let transport = RecordingTransport(
            data: Data("not json".utf8),
            response: httpResponse(200, url: url)
        )
        let session = AuthenticationSession(transport: transport)
        do {
            _ = try await session.authenticate(creds, on: profile)
            Issue.record("Expected malformedPayload")
        } catch {
            #expect(!String(describing: error).contains(secret))
            #expect(!String(reflecting: error).contains(secret))
        }
    }
}
