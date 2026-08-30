@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic, network-free coverage for
/// `URLSessionGameSocketFactory.swift`'s handshake-ordering fix:
/// ``WebSocketHandshakeGate`` (direct unit coverage of its own thread-safety/
/// idempotency) and ``GameSocketConnectDelegate`` (driven directly against its own
/// `URLSessionWebSocketDelegate`/`URLSessionTaskDelegate` callback methods -- the
/// exact production seam, with no fake/stand-in delegate of any kind).
///
/// Context: `didOpenWithProtocol` and `didCompleteWithError` each used to spawn
/// their own independent, unstructured `Task` directly into
/// `WebSocketConnectResolver`. Two separately spawned `Task`s racing each other are
/// not guaranteed to preserve `URLSession`'s own true chronological delegate-queue
/// callback ordering, so an open-then-immediate-close sequence could let the
/// "failed" `Task` win the race and misclassify an already-succeeded (HTTP 101)
/// handshake as a terminal failure. The fix records/checks
/// ``WebSocketHandshakeGate/recordOpened()``/``WebSocketHandshakeGate/wasAlreadyOpened()``
/// synchronously inside each callback's own body, before ever spawning a `Task` --
/// these tests drive both callbacks directly, in every relevant order, proving that
/// ordering decision no longer depends on `Task` scheduling at all.
@Suite("WebSocketHandshakeGate / GameSocketConnectDelegate ordering")
struct WebSocketHandshakeGateTests {
    // MARK: - WebSocketHandshakeGate (direct)

    @Test("A fresh gate reports not yet opened")
    func freshGateReportsNotYetOpened() {
        let gate = WebSocketHandshakeGate()
        #expect(!gate.wasAlreadyOpened())
    }

    @Test("recordOpened() makes wasAlreadyOpened() report true from then on")
    func recordOpenedMakesWasAlreadyOpenedTrue() {
        let gate = WebSocketHandshakeGate()
        gate.recordOpened()
        #expect(gate.wasAlreadyOpened())
    }

    @Test("recordOpened() is idempotent across repeated calls")
    func recordOpenedIsIdempotent() {
        let gate = WebSocketHandshakeGate()
        gate.recordOpened()
        gate.recordOpened()
        gate.recordOpened()
        #expect(gate.wasAlreadyOpened())
    }

    @Test("Many concurrent recordOpened()/wasAlreadyOpened() calls never crash or corrupt state")
    func concurrentAccessIsThreadSafe() async {
        let gate = WebSocketHandshakeGate()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 200 {
                group.addTask { gate.recordOpened() }
                group.addTask { _ = gate.wasAlreadyOpened() }
            }
        }
        // Every `recordOpened()` call raced above; once all have completed, the
        // gate is unconditionally left open -- proving no lost update under
        // concurrent access.
        #expect(gate.wasAlreadyOpened())
    }

    // MARK: - GameSocketConnectDelegate (production seam, driven directly)

    /// A `URLSessionTask` these tests can pass to `didCompleteWithError`, created
    /// via a real (never-resumed) `URLSessionWebSocketTask` from the caller's own
    /// `URLSession` (so a single ephemeral session per test is invalidated exactly
    /// once, rather than a second, separate one silently leaking) so its
    /// `.response` reads exactly as the production delegate expects (`nil`, since
    /// no real request/response ever occurred) without ever performing any actual
    /// network I/O.
    private func makeNeverResumedTask(session: URLSession) -> URLSessionWebSocketTask {
        session.webSocketTask(with: URL(string: "wss://example.invalid/socket")!)
    }

    @Test("Open observed, then complete: resolves connected, never failed")
    func openThenCompleteResolvesConnectedNeverFailed() async throws {
        let resolver = WebSocketConnectResolver()
        let delegate = GameSocketConnectDelegate(resolver: resolver)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = makeNeverResumedTask(session: session)

        delegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        delegate.urlSession(session, task: task, didCompleteWithError: nil)

        // Must not throw: the completion arriving after the open was already
        // observed is correctly treated as this connection subsequently closing,
        // never as a failed handshake.
        try await resolver.awaitConnected()
    }

    @Test("Complete alone, without any open ever observed, resolves failed (transport)")
    func completeAloneResolvesFailedTransport() async throws {
        let resolver = WebSocketConnectResolver()
        let delegate = GameSocketConnectDelegate(resolver: resolver)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = makeNeverResumedTask(session: session)

        delegate.urlSession(session, task: task, didCompleteWithError: nil)

        await #expect(throws: GameSocketConnectError.transport) {
            try await resolver.awaitConnected()
        }
    }

    @Test("""
    Complete arriving before open ever fires (the pathological reversed order) is \
    classified identically to complete-alone: a genuine failed handshake, never a \
    false-positive success
    """)
    func completeBeforeOpenResolvesFailed() async throws {
        let resolver = WebSocketConnectResolver()
        let delegate = GameSocketConnectDelegate(resolver: resolver)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = makeNeverResumedTask(session: session)

        // Deliberately reversed: complete fires, and only *afterward* does this
        // test simulate what would have been a (never-actually-arriving in this
        // scenario) open callback -- proving a late/absent open cannot retroactively
        // rescue an already-resolved failure.
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        delegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)

        await #expect(throws: GameSocketConnectError.transport) {
            try await resolver.awaitConnected()
        }
    }

    @Test("Complete with a genuine transport error (e.g. cancellation) and no open resolves failed")
    func completeWithGenuineErrorAndNoOpenResolvesFailed() async throws {
        let resolver = WebSocketConnectResolver()
        let delegate = GameSocketConnectDelegate(resolver: resolver)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = makeNeverResumedTask(session: session)

        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))

        await #expect(throws: GameSocketConnectError.transport) {
            try await resolver.awaitConnected()
        }
    }

    @Test("A repeated complete callback after open is a harmless no-op every time")
    func repeatedCompleteAfterOpenIsANoOp() async throws {
        let resolver = WebSocketConnectResolver()
        let delegate = GameSocketConnectDelegate(resolver: resolver)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = makeNeverResumedTask(session: session)

        delegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))

        try await resolver.awaitConnected()
    }

    @Test("""
    Many independent open-then-complete delegate instances, exercised concurrently \
    against each other (though each individual instance still observes open \
    strictly before complete, exactly as URLSession's own serial delegate queue \
    guarantees), always resolve connected -- never failed -- proving the ordering \
    fix's lock/actor plumbing holds under real concurrent load, not merely one \
    instance at a time
    """)
    func concurrentOpenThenCompleteStressNeverMisclassifiesAsFailed() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 200 {
                group.addTask {
                    let resolver = WebSocketConnectResolver()
                    let delegate = GameSocketConnectDelegate(resolver: resolver)
                    let session = URLSession(configuration: .ephemeral)
                    defer { session.invalidateAndCancel() }
                    let task = makeNeverResumedTask(session: session)
                    // Sequential within this one instance -- matching exactly what
                    // `URLSession`'s own serial delegate queue guarantees for a
                    // connection that opened before it was later closed -- while
                    // many such instances run concurrently against each other
                    // across the surrounding task group, stressing the gate's
                    // lock and the resolver actor under genuine concurrent load.
                    delegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
                    delegate.urlSession(session, task: task, didCompleteWithError: nil)
                    try await resolver.awaitConnected()
                }
            }
            try await group.waitForAll()
        }
    }
}
