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
    ///
    /// Fails fast via `preconditionFailure` if the deadline elapses first,
    /// rather than silently returning: this is test-only infrastructure, so
    /// letting a caller proceed without the expected call count ever having
    /// been reached would let a test continue in an already-invalid state
    /// and fail later, if at all, with a confusing, seemingly-unrelated
    /// symptom instead of reporting the real cause (a fetch that never
    /// started, or started fewer times than expected) at the point it
    /// actually happened.
    ///
    /// The default is deliberately generous (not a tight bound tied to any
    /// expected latency): under a heavily parallel CI run sharing a single
    /// process with this package's full test suite (which also spawns real
    /// subprocesses with their own multi-second deadlines, e.g.
    /// `SubprocessDeadlineGuardMechanicsTests`), Swift Testing's own task
    /// scheduling can legitimately delay when a *cooperative* actor hop
    /// like this fake transport's `fetch` first runs, even though nothing
    /// is actually hung. A caller that genuinely never starts the expected
    /// fetch still fails this precondition — just after tolerating
    /// ordinary scheduling contention rather than a fixed, tight deadline
    /// that mistakes CI load for a production bug.
    func waitForCallCount(
        _ count: Int,
        for url: URL,
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while startedCounts[url, default: 0] < count {
            guard !Self.isPast(deadline) else {
                preconditionFailure(
                    "waitForCallCount(\(count), for: \(url)) timed out after "
                        + "\(timeoutNanoseconds / 1_000_000)ms; only "
                        + "\(startedCounts[url, default: 0]) call(s) had started"
                )
            }
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
