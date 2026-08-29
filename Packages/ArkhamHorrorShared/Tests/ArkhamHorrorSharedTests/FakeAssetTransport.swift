@testable import ArkhamHorrorShared
import Foundation

/// A fully scripted, in-memory ``AssetTransport`` fake: no networking, no
/// filesystem access. Each URL has its own FIFO queue of results (either a
/// success ``AssetHTTPResult`` or an error to throw), and any URL can be
/// "held" so its next fetch suspends (cooperatively, responding to
/// cancellation like a real network call would) until the test explicitly
/// releases it — this is what lets tests exercise coalescing and
/// cancellation semantics deterministically, without timing-dependent
/// sleeps standing in for a real slow network.
actor FakeAssetTransport: AssetTransport {
    struct Call: Sendable, Equatable {
        let url: URL
        let ifNoneMatch: String?
        let ifModifiedSince: String?
    }

    private(set) var calls: [Call] = []
    private var scriptedResults: [URL: [Result<AssetHTTPResult, Error>]] = [:]
    private var heldURLs: Set<URL> = []
    private var startedCounts: [URL: Int] = [:]

    func enqueue(_ result: Result<AssetHTTPResult, Error>, for url: URL) {
        scriptedResults[url, default: []].append(result)
    }

    func hold(_ url: URL) {
        heldURLs.insert(url)
    }

    func release(_ url: URL) {
        heldURLs.remove(url)
    }

    func callCount(for url: URL) -> Int {
        startedCounts[url, default: 0]
    }

    /// Polls (test-only; not a production concurrency pattern) until at
    /// least `count` fetches for `url` have started, or `timeoutNanoseconds`
    /// elapses.
    func waitForCallCount(
        _ count: Int,
        for url: URL,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while startedCounts[url, default: 0] < count, !Self.isPast(deadline) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func isPast(_ deadline: UInt64) -> Bool {
        DispatchTime.now().uptimeNanoseconds >= deadline
    }

    func fetch(
        _ request: AssetHTTPRequest,
        limits _: AssetCacheLimits
    ) async throws -> AssetHTTPResult {
        calls.append(Call(
            url: request.url,
            ifNoneMatch: request.ifNoneMatch,
            ifModifiedSince: request.ifModifiedSince
        ))
        startedCounts[request.url, default: 0] += 1

        while heldURLs.contains(request.url) {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try Task.checkCancellation()

        guard var queue = scriptedResults[request.url], !queue.isEmpty else {
            throw AssetError.unexpectedStatus(599)
        }
        let next = queue.removeFirst()
        scriptedResults[request.url] = queue
        return try next.get()
    }
}
