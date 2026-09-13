@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Production assignment replay bounded transport")
struct AssignmentReplayBoundedTransportTests {
    @Test("Declared and streaming response sizes are bounded")
    func responseSizeLimits() async throws {
        let declaredURL = try #require(
            URL(string: "https://assignment-replay.test/declared")
        )
        AssignmentReplayURLProtocol.register(
            declaredURL,
            data: Data([0x41]),
            declaredLength: 65
        )
        let declaredTransport = try AssignmentReplayBoundedHTTPTransport(
            maxByteCount: 64,
            timeout: 5,
            protocolClasses: [AssignmentReplayURLProtocol.self]
        )
        await #expect(
            throws: AssignmentReplayBoundedTransportError.responseTooLarge
        ) {
            _ = try await declaredTransport.data(
                for: URLRequest(url: declaredURL)
            )
        }
        #expect(await AssignmentReplayURLProtocol.awaitStop(declaredURL))

        let streamingURL = try #require(
            URL(string: "https://assignment-replay.test/streaming")
        )
        AssignmentReplayURLProtocol.register(
            streamingURL,
            data: Data(repeating: 0x42, count: 65)
        )
        let streamingTransport = try AssignmentReplayBoundedHTTPTransport(
            maxByteCount: 64,
            timeout: 5,
            protocolClasses: [AssignmentReplayURLProtocol.self]
        )
        await #expect(
            throws: AssignmentReplayBoundedTransportError.responseTooLarge
        ) {
            _ = try await streamingTransport.data(
                for: URLRequest(url: streamingURL)
            )
        }
        #expect(await AssignmentReplayURLProtocol.awaitStop(streamingURL))
    }

    @Test("Capability and game recorders retain the bounded base transport")
    func replayBootstrapWrappersRemainBounded() async throws {
        let capabilityURL = try #require(
            URL(string: "https://assignment-replay.test/capabilities")
        )
        AssignmentReplayURLProtocol.register(
            capabilityURL,
            data: Data(repeating: 0x41, count: 65)
        )
        let capabilityBase = try AssignmentReplayBoundedHTTPTransport(
            maxByteCount: 64,
            timeout: 5,
            protocolClasses: [AssignmentReplayURLProtocol.self]
        )
        let capabilityTransport = AssignmentReplayCapabilityTransport(
            base: capabilityBase
        )
        await #expect(
            throws: AssignmentReplayBoundedTransportError.responseTooLarge
        ) {
            _ = try await capabilityTransport.data(
                for: URLRequest(url: capabilityURL)
            )
        }

        let gameURL = try #require(
            URL(string: "https://assignment-replay.test/game")
        )
        AssignmentReplayURLProtocol.register(
            gameURL,
            data: Data(repeating: 0x42, count: 65)
        )
        let gameBase = try AssignmentReplayBoundedHTTPTransport(
            maxByteCount: 64,
            timeout: 5,
            protocolClasses: [AssignmentReplayURLProtocol.self]
        )
        let gameTransport = AssignmentReplayRecordingGameTransport(
            base: gameBase
        )
        await #expect(
            throws: AssignmentReplayBoundedTransportError.responseTooLarge
        ) {
            _ = try await gameTransport.data(
                for: URLRequest(url: gameURL)
            )
        }
    }

    @Test("Authentication bootstrap retains the bounded base transport")
    func authenticationBootstrapRemainsBounded() async throws {
        let profile = ServerProfile.hosted
        let url = profile.endpointURL(path: "/whoami")
        AssignmentReplayURLProtocol.register(
            url,
            data: Data(repeating: 0x41, count: 65)
        )
        let transport = try AssignmentReplayBoundedHTTPTransport(
            maxByteCount: 64,
            timeout: 5,
            protocolClasses: [AssignmentReplayURLProtocol.self]
        )
        let session = AuthenticationSession(transport: transport)

        do {
            _ = try await session.currentUser(
                on: profile,
                token: "replay-token"
            )
            Issue.record("Expected the bounded authentication request to fail")
        } catch let error as AuthenticationError {
            guard case .transportFailure = error else {
                Issue.record("Expected an authentication transport failure")
                return
            }
        } catch {
            Issue.record("Expected an AuthenticationError")
        }
        #expect(await AssignmentReplayURLProtocol.awaitStop(url))
    }

    @Test("Expired absolute deadline rejects locale bootstrap before networking")
    func expiredLocaleDeadline() async throws {
        let deadline = try AssignmentReplayCoordinatorDeadline(
            rawValue: String(DispatchTime.now().uptimeNanoseconds - 1)
        )
        let transport = ReplayDeadlineLocaleTransport(
            deadline: deadline
        )
        await #expect(
            throws: ProductionAssignmentReplayCoordinatorError.deadlineExpired
        ) {
            _ = try await transport.fetch(
                #require(URL(string: "https://assignment-replay.test/catalog")),
                maxBytes: 64
            )
        }
    }

    @Test("Expired absolute deadline rejects a socket before connecting")
    func expiredSocketDeadline() async throws {
        let deadline = try AssignmentReplayCoordinatorDeadline(
            rawValue: String(DispatchTime.now().uptimeNanoseconds - 1)
        )
        let base = AssignmentReplaySocketFactoryProbe()
        let factory = AssignmentReplayDeadlineSocketFactory(
            deadline: deadline,
            base: base
        )
        await #expect(
            throws: ProductionAssignmentReplayCoordinatorError.deadlineExpired
        ) {
            _ = try await factory.connect(
                to: #require(URL(string: "wss://assignment-replay.test/game"))
            )
        }
        #expect(await base.connectCallCount == 0)
    }
}

private actor AssignmentReplaySocketFactoryProbe: GameSocketFactory {
    private(set) var connectCallCount = 0

    func connect(to _: URL) async throws -> any GameSocketConnection {
        connectCallCount += 1
        throw TestFailure()
    }
}

private final class AssignmentReplayURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Response {
        let data: Data
        let declaredLength: Int?
    }

    private static let lock = NSLock()
    // swiftlint:disable:next modifier_order
    private nonisolated(unsafe) static var responses: [URL: Response] = [:]
    // swiftlint:disable:next modifier_order
    private nonisolated(unsafe) static var stopped: Set<URL> = []
    static func register(
        _ url: URL,
        data: Data,
        declaredLength: Int? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        responses[url] = Response(
            data: data,
            declaredLength: declaredLength
        )
        stopped.remove(url)
    }

    static func awaitStop(_ url: URL) async -> Bool {
        for _ in 0 ..< 100 {
            if wasStopped(url) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return wasStopped(url)
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        lock.lock()
        defer { lock.unlock() }
        return responses[url] != nil
    }

    override static func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = Self.response(for: url),
              let httpResponse = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: response.declaredLength.map {
                      ["Content-Length": String($0)]
                  }
              )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: httpResponse,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.stopped.insert(url)
        Self.lock.unlock()
    }

    private static func response(for url: URL) -> Response? {
        lock.lock()
        defer { lock.unlock() }
        return responses[url]
    }

    private static func wasStopped(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped.contains(url)
    }
}
