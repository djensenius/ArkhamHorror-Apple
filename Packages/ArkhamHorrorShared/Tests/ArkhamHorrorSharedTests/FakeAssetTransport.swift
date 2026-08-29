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

    private struct ScriptedEntry {
        let result: Result<AssetHTTPResult, Error>
        let delayNanoseconds: UInt64
    }

    private(set) var calls: [Call] = []
    private var scriptedResults: [URL: [ScriptedEntry]] = [:]
    private var heldURLs: Set<URL> = []
    private var startedCounts: [URL: Int] = [:]

    func enqueue(_ result: Result<AssetHTTPResult, Error>, for url: URL) {
        scriptedResults[url, default: []].append(
            ScriptedEntry(result: result, delayNanoseconds: 0)
        )
    }

    /// Like ``enqueue(_:for:)``, but the returned result is only handed back
    /// after an explicit delay. This lets tests deterministically make a
    /// request that *started* later actually *complete* first (and vice
    /// versa), to exercise out-of-order/stale-completion protections without
    /// depending on ambient task-scheduling order.
    func enqueue(
        _ result: Result<AssetHTTPResult, Error>,
        for url: URL,
        delayNanoseconds: UInt64
    ) {
        scriptedResults[url, default: []].append(
            ScriptedEntry(result: result, delayNanoseconds: delayNanoseconds)
        )
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
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try Task.checkCancellation()

        guard var queue = scriptedResults[request.url], !queue.isEmpty else {
            throw AssetError.unexpectedStatus(599)
        }
        let next = queue.removeFirst()
        scriptedResults[request.url] = queue
        if next.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: next.delayNanoseconds)
        }
        return try next.result.get()
    }
}
