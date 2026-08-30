import Foundation

/// Resolves the single "did this WebSocket handshake succeed or fail" transition for
/// one connection attempt, bridging ``URLSessionWebSocketDelegate``'s two possible
/// outcome callbacks (`didOpenWithProtocol`/`didCompleteWithError`) into one awaitable
/// result. An `actor` so both callbacks (arriving on an arbitrary delegate queue) and
/// the awaiting caller serialize safely without a manual lock.
///
/// At most one of ``resolveOpened()``/``resolveFailed(_:)`` ever has an effect: once
/// either resolves this connection attempt, every later call (including a
/// `didCompleteWithError` that fires *after* a successful open, once the connection
/// later closes) is a deliberate no-op, since ``URLSessionGameSocketFactory/connect(to:)``
/// has already returned by then and this resolver's job is done.
actor WebSocketConnectResolver {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var isResolved = false
    private var failure: (any Error)?

    /// Suspends until this attempt resolves, throwing whatever error
    /// ``resolveFailed(_:)`` was given if it resolved that way.
    func awaitConnected() async throws {
        if isResolved {
            if let failure {
                throw failure
            }
            return
        }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resolveOpened() {
        guard !isResolved else { return }
        isResolved = true
        continuation?.resume()
        continuation = nil
    }

    func resolveFailed(_ error: any Error) {
        guard !isResolved else { return }
        isResolved = true
        failure = error
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Synchronously (and thread-safely) captures whether a WebSocket handshake has
/// already been observed to open, entirely independent of any subsequent async
/// scheduling.
///
/// This exists to fix an ordering hazard: `didOpenWithProtocol` and
/// `didCompleteWithError` each used to spawn their own independent, unstructured
/// `Task` directly into ``WebSocketConnectResolver``. `URLSession`'s delegate queue
/// delivers both callbacks in true chronological order (this factory's session is
/// constructed with `delegateQueue: nil`, a private serial `OperationQueue`), but two
/// separately spawned `Task`s racing each other to call into the resolver actor are
/// not guaranteed to preserve that relative ordering -- so an open-then-immediate-
/// close sequence could let the "failed" `Task` win the race and misclassify an
/// already-succeeded (HTTP 101) handshake as a terminal failure. Recording/checking
/// this flag happens synchronously inside each delegate callback's own body (already
/// serialized by the delegate queue itself), *before* ever handing off to the async
/// resolver actor, so the ordering decision itself never depends on `Task`
/// scheduling at all. The lock is kept anyway (rather than relying purely on the
/// delegate queue's documented seriality) for a self-contained invariant that holds
/// independent of how this delegate happens to be configured.
final class WebSocketHandshakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasOpened = false

    /// Records that the handshake has opened. Idempotent; safe to call more than
    /// once (`didOpenWithProtocol` is only ever expected to fire at most once per
    /// task, but this makes no assumption either way).
    func recordOpened() {
        lock.lock()
        defer { lock.unlock() }
        hasOpened = true
    }

    /// Whether ``recordOpened()`` has already been called at least once, as of this
    /// exact call.
    func wasAlreadyOpened() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasOpened
    }
}

/// Bridges `URLSessionWebSocketDelegate`/`URLSessionTaskDelegate` callbacks for one
/// connection attempt to a ``WebSocketConnectResolver``. A fresh instance per
/// attempt (assigned as `URLSessionWebSocketTask.delegate`, a per-task delegate
/// supported since iOS 15/macOS 12), so no state from a previous attempt on the same
/// factory can ever leak into a new one.
final class GameSocketConnectDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let resolver: WebSocketConnectResolver
    private let handshakeGate = WebSocketHandshakeGate()

    init(resolver: WebSocketConnectResolver) {
        self.resolver = resolver
    }

    func urlSession(
        _: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?
    ) {
        // Recorded synchronously, before ever spawning the `Task` below -- see
        // `WebSocketHandshakeGate`'s own documentation for why this ordering matters.
        handshakeGate.recordOpened()
        Task { await resolver.resolveOpened() }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError _: (any Error)?) {
        // Checked synchronously, before ever inspecting `task.response` or spawning
        // a `Task`: if the handshake was already observed to open (whether that
        // happened strictly before this callback, or this callback is simply racing
        // an in-flight `didOpenWithProtocol` on the very same serial delegate
        // queue), this completion can only be the connection subsequently closing --
        // never a failed handshake -- and reporting a failure here would incorrectly
        // resolve (or attempt to resolve) an already-succeeded connect attempt.
        guard !handshakeGate.wasAlreadyOpened() else { return }
        // Fires once the task fully completes for *any* reason. Reached here only
        // when the handshake itself failed (the gate above already excluded "opened,
        // then later closed"): `task.response` is still populated with the
        // pre-upgrade `HTTPURLResponse` in that case (e.g. a 401 the backend sends
        // instead of ever upgrading the connection), which is why the HTTP status --
        // and only the status, never any header or body -- is surfaced here.
        if let status = (task.response as? HTTPURLResponse)?.statusCode {
            Task { await resolver.resolveFailed(GameSocketConnectError.http(status: status)) }
        } else {
            Task { await resolver.resolveFailed(GameSocketConnectError.transport) }
        }
    }
}

/// The production ``GameSocketConnection``, backed by one `URLSessionWebSocketTask`.
final class URLSessionGameSocketConnection: GameSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    /// Retained only so the delegate (which the session already holds strongly for
    /// the task's lifetime) cannot be deallocated a moment early by some other path;
    /// never read after construction.
    private let connectDelegate: AnyObject

    fileprivate init(task: URLSessionWebSocketTask, connectDelegate: AnyObject) {
        self.task = task
        self.connectDelegate = connectDelegate
    }

    func nextEvent() async throws -> GameSocketEvent {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            // `closeCode` remains `.invalid` until a closing handshake actually
            // completes (locally- or remotely-initiated); only then does a
            // `receive()` failure represent a clean close rather than a genuine
            // network loss. See `GameSocketEvent.closed`'s documentation for why
            // both currently drive identical reconnect behavior regardless.
            if task.closeCode != .invalid {
                return .closed(code: task.closeCode, reason: task.closeReason)
            }
            throw GameSocketTransportError()
        }
        switch message {
        case let .data(data):
            return .message(data)
        case let .string(string):
            return .message(Data(string.utf8))
        @unknown default:
            // A wire-message kind this OS version's `URLSessionWebSocketTask` API
            // doesn't yet expose to us -- a transport-level surprise, not a
            // malformed contract payload. Route it through the same transport
            // failure/retry-with-backoff path as any other `receive()` failure,
            // rather than fabricating fake message bytes that would masquerade as
            // a genuine (and always-failing) contract decode issue.
            throw GameSocketTransportError()
        }
    }

    func close(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: code, reason: reason)
    }
}

/// The production ``GameSocketFactory``, backed by a dedicated ephemeral,
/// credential- and cookie-free `URLSession` -- the same isolation
/// ``URLSessionTransport`` gives every REST request in this package, so a live-game
/// socket never draws from (or leaks into) shared cookie/credential/cache state
/// either.
struct URLSessionGameSocketFactory: GameSocketFactory {
    private let session: URLSession

    /// Creates a factory backed by a new ephemeral, credential- and cookie-free
    /// session, mirroring ``URLSessionTransport/init()`` exactly.
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }

    func connect(to url: URL) async throws -> any GameSocketConnection {
        let task = session.webSocketTask(with: url)
        let resolver = WebSocketConnectResolver()
        let delegate = GameSocketConnectDelegate(resolver: resolver)
        task.delegate = delegate
        task.resume()
        do {
            try await withTaskCancellationHandler {
                try await resolver.awaitConnected()
            } onCancel: {
                // Synchronous, per `GameSocketConnection.close(code:reason:)`'s own
                // contract, so an outer cancellation interrupts an in-flight
                // handshake immediately rather than waiting for it to time out on
                // its own.
                task.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            // A cancellation-triggered local `task.cancel(...)` above resolves the
            // resolver with `GameSocketConnectError.transport` (no HTTP response was
            // ever received), which would otherwise be indistinguishable from a
            // genuine transport failure; re-checking cancellation here -- exactly
            // the idiom `GameLifecycleService.performRaw(_:)` uses -- ensures a
            // cancelled caller always observes `CancellationError`, never a
            // same-shaped `GameSocketConnectError.transport`.
            try Task.checkCancellation()
            throw error
        }
        return URLSessionGameSocketConnection(task: task, connectDelegate: delegate)
    }
}
