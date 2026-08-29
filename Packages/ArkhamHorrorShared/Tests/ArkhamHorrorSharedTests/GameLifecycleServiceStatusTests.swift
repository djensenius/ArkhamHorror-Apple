@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Split out of `GameLifecycleServiceTests.swift` purely by file/type-body length:
/// status-code mapping, cancellation, and secret-leakage coverage for
/// ``GameLifecycleService``, using the same shared transport fakes
/// (`GameLifecycleTestSupport.swift`).
@Suite("GameLifecycleService — status, cancellation, secrets")
struct GameLifecycleServiceStatusTests {
    private let profile = ServerProfile.hosted
    private let token = "the-session-token"

    private func httpResponse(_ status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    // MARK: - Status mapping

    @Test("HTTP 401 maps to sessionExpired")
    func unauthorizedMapsToSessionExpired() async {
        let url = profile.endpointURL(path: "/arkham/games")
        let transport = GameLifecycleRecordingTransport(
            data: Data(), response: httpResponse(401, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        await #expect(throws: GameLifecycleError.sessionExpired) {
            try await service.listGames(on: profile, token: token)
        }
    }

    @Test("An unexpected status maps to unexpectedStatus")
    func unexpectedStatusMaps() async {
        let url = profile.endpointURL(path: "/arkham/games")
        let transport = GameLifecycleRecordingTransport(
            data: Data(), response: httpResponse(403, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        await #expect(throws: GameLifecycleError.unexpectedStatus(403)) {
            try await service.listGames(on: profile, token: token)
        }
    }

    @Test("A malformed 2xx body maps to malformedPayload")
    func malformedBodyMaps() async {
        let url = profile.endpointURL(path: "/arkham/games")
        let transport = GameLifecycleRecordingTransport(
            data: Data("not json".utf8), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        await #expect(throws: GameLifecycleError.malformedPayload) {
            try await service.listGames(on: profile, token: token)
        }
    }

    @Test("A non-HTTP response maps to nonHTTPResponse")
    func nonHTTPResponseMaps() async throws {
        struct NonHTTPTransport: HTTPTransport {
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                try (
                    Data(),
                    URLResponse(
                        url: #require(request.url), mimeType: nil, expectedContentLength: 0,
                        textEncodingName: nil
                    )
                )
            }
        }
        let service = GameLifecycleService(transport: NonHTTPTransport())
        await #expect(throws: GameLifecycleError.nonHTTPResponse) {
            try await service.listGames(on: profile, token: token)
        }
    }

    @Test("A transport-level failure maps to transportFailure")
    func transportFailureMaps() async {
        let service = GameLifecycleService(
            transport: GameLifecycleFailingTransport(error: GameLifecycleTransportFailure())
        )
        await #expect(throws: GameLifecycleError.transportFailure("")) {
            try await service.listGames(on: profile, token: token)
        }
    }

    // MARK: - Cancellation

    @Test("A transport-thrown CancellationError is not wrapped")
    func cancellationNotWrapped() async {
        let service = GameLifecycleService(
            transport: GameLifecycleFailingTransport(error: CancellationError())
        )
        await #expect(throws: CancellationError.self) {
            try await service.listGames(on: profile, token: token)
        }
    }

    @Test("URLError.cancelled from a cancelled task surfaces as CancellationError")
    func urlErrorCancelledSurfacesAsCancellation() async {
        let transport = GameLifecycleGatedTransport()
        let service = GameLifecycleService(transport: transport)
        let task = Task<GameList, any Error> {
            try await service.listGames(on: profile, token: token)
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
        let url = profile.endpointURL(path: "/arkham/games")
        let transport = GameLifecycleGatedTransport()
        let service = GameLifecycleService(transport: transport)
        let task = Task<GameList, any Error> {
            try await service.listGames(on: profile, token: token)
        }
        let gate = await transport.awaitGate()
        task.cancel()
        gate.resume(returning: (Data("[]".utf8), httpResponse(200, url: url)))
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    // MARK: - No secret leakage

    @Test("Errors never contain the session token")
    func errorsDoNotLeakToken() async {
        let secretToken = "very-secret-token-value"
        let url = profile.endpointURL(path: "/arkham/games")
        let transport = GameLifecycleRecordingTransport(
            data: Data("not json".utf8), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        do {
            _ = try await service.listGames(on: profile, token: secretToken)
            Issue.record("Expected malformedPayload")
        } catch {
            #expect(!String(describing: error).contains(secretToken))
            #expect(!String(reflecting: error).contains(secretToken))
        }
    }
}
