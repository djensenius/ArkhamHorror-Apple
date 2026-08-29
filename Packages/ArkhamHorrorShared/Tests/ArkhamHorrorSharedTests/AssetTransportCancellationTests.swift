@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Production-seam regression coverage for `URLSessionAssetTransport`:
/// every non-2xx status (304/404/3xx/other) must promptly cancel the
/// underlying `URLSessionTask` once its headers have been inspected,
/// rather than leaving `URLSession.AsyncBytes` free to keep receiving an
/// unbounded body nobody will ever read. `AssetTransport`'s fake
/// conformance used elsewhere in this test target cannot observe this:
/// only a real `URLSession` request, intercepted by a `URLProtocol` stub,
/// can prove the concrete `URLSessionTask` was actually torn down.
///
/// The stub below continuously feeds body chunks on a background queue
/// until its own `stopLoading()` fires (which only happens once the task
/// is cancelled): a single isolated chunk is not sufficient to
/// distinguish "explicitly cancelled promptly" from "left running, but
/// incidentally torn down later by unrelated deinitialization," which a
/// weaker single-chunk stub cannot tell apart.
struct AssetTransportCancellationTests {
    /// Thread-safe recorder observing whether the stub protocol's
    /// `stopLoading()` (called only when its task is cancelled or
    /// otherwise torn down) has fired for a given request URL, and
    /// carrying the flag the feeding loop polls to stop sending chunks.
    /// Shared with `NonDrainingStatusURLProtocol` instances, which the URL
    /// loading system creates and owns itself -- a test cannot hold a
    /// direct reference to the instance handling its own request.
    final class CancellationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stopLoadingCalled = false
        private var chunksSentAfterStop = 0
        private var totalChunksSent = 0

        func recordStopLoading() {
            lock.lock()
            defer { lock.unlock() }
            stopLoadingCalled = true
        }

        func hasStopped() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopLoadingCalled
        }

        /// Called by the feeding loop immediately before every chunk it
        /// sends; counts how many chunks were sent after `stopLoading()`
        /// had already fired, so a test can assert the feeding loop
        /// itself promptly noticed cancellation rather than merely that
        /// `stopLoading()` eventually fired on some unrelated schedule.
        func recordChunkSent() {
            lock.lock()
            defer { lock.unlock() }
            totalChunksSent += 1
            if stopLoadingCalled {
                chunksSentAfterStop += 1
            }
        }

        func chunksSentAfterStopCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return chunksSentAfterStop
        }

        func totalChunksSentCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return totalChunksSent
        }
    }

    /// Maps each test's unique request URL to the status code the stub
    /// should respond with and the recorder that should observe its
    /// cancellation, since `URLProtocol` subclasses are instantiated
    /// internally by the URL loading system rather than by the test.
    final class StubRegistry: @unchecked Sendable {
        static let shared = StubRegistry()
        private let lock = NSLock()
        private var statusCodes: [URL: Int] = [:]
        private var recorders: [URL: CancellationRecorder] = [:]

        func register(url: URL, status: Int, recorder: CancellationRecorder) {
            lock.lock()
            defer { lock.unlock() }
            statusCodes[url] = status
            recorders[url] = recorder
        }

        func status(for url: URL) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            return statusCodes[url]
        }

        func recorder(for url: URL) -> CancellationRecorder? {
            lock.lock()
            defer { lock.unlock() }
            return recorders[url]
        }
    }

    /// Responds with a registered status code, then continuously feeds
    /// body chunks on a background queue -- simulating a body that would
    /// keep arriving forever if the caller never bounds it -- until
    /// `stopLoading()` fires (only ever called by the URL loading system
    /// once the task has actually been cancelled). Caps the feeding loop
    /// at a generous maximum duration purely so a genuinely regressed
    /// transport does not leave a runaway background thread alive for
    /// the rest of the test process.
    final class NonDrainingStatusURLProtocol: URLProtocol, @unchecked Sendable {
        private static let maxFeedIterations = 400
        private static let feedInterval: TimeInterval = 0.005

        override static func canInit(with request: URLRequest) -> Bool {
            guard let url = request.url else { return false }
            return StubRegistry.shared.status(for: url) != nil
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard
                let url = request.url,
                let status = StubRegistry.shared.status(for: url),
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let recorder = StubRegistry.shared.recorder(for: url)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

            let feedQueue = DispatchQueue(label: "non-draining-body-feed")
            feedQueue.async { [weak self] in
                for _ in 0 ..< Self.maxFeedIterations {
                    guard let self, let recorder, !recorder.hasStopped() else { return }
                    recorder.recordChunkSent()
                    client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 4096))
                    Thread.sleep(forTimeInterval: Self.feedInterval)
                }
            }
        }

        override func stopLoading() {
            if let url = request.url {
                StubRegistry.shared.recorder(for: url)?.recordStopLoading()
            }
        }
    }

    private func standardLimits() -> AssetCacheLimits {
        AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 10_000_000,
            diskBudgetBytes: 10_000_000
        )
    }

    /// Polls rather than asserting immediately: task cancellation
    /// completes asynchronously relative to `fetch`'s own return, and the
    /// full test suite's parallel execution can introduce real scheduling
    /// jitter. A 3-second bound is still generous relative to
    /// `NonDrainingStatusURLProtocol.maxFeedIterations` (400 iterations at
    /// a 5ms cadence, ~2 seconds), so a transport that never cancels
    /// reliably times out rather than the test hanging indefinitely.
    private func waitUntilStopped(_ recorder: CancellationRecorder) async throws {
        for _ in 0 ..< 600 where !recorder.hasStopped() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func assertPromptCancellation(
        status: Int,
        expectedResult: @escaping @Sendable (AssetHTTPResult) -> Bool
    ) async throws {
        let recorder = CancellationRecorder()
        let url = try #require(URL(string: "https://transport-stub.test/\(UUID().uuidString)"))
        StubRegistry.shared.register(url: url, status: status, recorder: recorder)
        let transport = URLSessionAssetTransport(
            protocolClasses: [NonDrainingStatusURLProtocol.self]
        )

        let result = try await transport.fetch(AssetHTTPRequest(url: url), limits: standardLimits())
        #expect(expectedResult(result), "Unexpected result for status \(status): \(result)")

        try await waitUntilStopped(recorder)
        assertStoppedPromptly(recorder, status: status)
    }

    private func assertPromptCancellation(status: Int, expectedError: AssetError) async throws {
        let recorder = CancellationRecorder()
        let url = try #require(URL(string: "https://transport-stub.test/\(UUID().uuidString)"))
        StubRegistry.shared.register(url: url, status: status, recorder: recorder)
        let transport = URLSessionAssetTransport(
            protocolClasses: [NonDrainingStatusURLProtocol.self]
        )

        await #expect(throws: expectedError) {
            _ = try await transport.fetch(AssetHTTPRequest(url: url), limits: standardLimits())
        }

        try await waitUntilStopped(recorder)
        assertStoppedPromptly(recorder, status: status)
    }

    /// Common assertions once `fetch` has returned/thrown: the task must
    /// have been (or must promptly become) cancelled, the feeding loop
    /// must not have squeezed in another chunk after noticing that, and
    /// -- the single strongest bound this environment can prove, given
    /// that `URLSession.AsyncBytes`'s own deinit also races to cancel an
    /// abandoned task once nothing references it any longer, and that a
    /// fully parallel test-suite run introduces real scheduling jitter on
    /// the feeding loop's background queue -- the total number of chunks
    /// the stub ever managed to send must stay well clear of
    /// `NonDrainingStatusURLProtocol.maxFeedIterations` (400), so a
    /// regression that silently disabled cancellation (relying solely on
    /// some other, much slower teardown path) would still make this test
    /// fail rather than pass by coincidence.
    private func assertStoppedPromptly(_ recorder: CancellationRecorder, status: Int) {
        #expect(
            recorder.hasStopped(),
            "Status \(status)'s underlying task must be cancelled, not left to drain indefinitely"
        )
        #expect(
            recorder.chunksSentAfterStopCount() == 0,
            "The feeding loop must notice cancellation before sending another chunk"
        )
        #expect(
            recorder.totalChunksSentCount() <= 100,
            "Status \(status)'s body must stop arriving well before the feeding loop's own cap"
        )
    }

    @Test("A 304 response promptly cancels the underlying task rather than draining a body forever")
    func notModifiedCancelsUnderlyingTask() async throws {
        try await assertPromptCancellation(status: 304) { $0 == .notModified }
    }

    @Test("A 404 response promptly cancels the underlying task rather than draining a body forever")
    func notFoundCancelsUnderlyingTask() async throws {
        try await assertPromptCancellation(status: 404) { $0 == .notFound }
    }

    @Test(
        "A rejected redirect promptly cancels the underlying task, not draining the body forever"
    )
    func redirectRejectionCancelsUnderlyingTask() async throws {
        try await assertPromptCancellation(
            status: 302,
            expectedError: .redirectRejected(status: 302)
        )
    }

    @Test(
        "An unexpected status promptly cancels the underlying task, not draining the body forever"
    )
    func unexpectedStatusCancelsUnderlyingTask() async throws {
        try await assertPromptCancellation(status: 500, expectedError: .unexpectedStatus(500))
    }
}
