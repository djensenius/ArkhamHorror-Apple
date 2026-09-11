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
