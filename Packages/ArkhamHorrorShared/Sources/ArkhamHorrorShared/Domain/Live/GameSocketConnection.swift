import Foundation

/// One frame surfaced by an open ``GameSocketConnection``.
enum GameSocketEvent: Sendable, Equatable {
    /// A single WebSocket message's raw bytes, not yet decoded through
    /// ``ContractJSON``. A text frame is UTF-8-encoded into `Data` by the production
    /// conformance so every caller decodes exactly one representation.
    case message(Data)
    /// The server (or an intermediary) completed a clean WebSocket closing
    /// handshake before this connection was otherwise torn down locally.
    /// Distinguished from a thrown ``GameSocketTransportError`` (network loss with no
    /// closing handshake) so a test -- and a future diagnostic -- can tell the two
    /// apart, even though both currently drive the exact same reconnect-with-backoff
    /// behavior (see `AppModel+LiveGameSession.swift`): the production backend
    /// closes quiet-room sockets on its own idle timeout as routine churn, not as a
    /// signal this client should stop reconnecting.
    case closed(code: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

/// A WebSocket connection was lost without completing a clean closing handshake
/// (network drop, timeout, process death). Carries no diagnostic text derived from
/// the underlying system error: that text frequently embeds the failing request's
/// URL, which for this connection always contains the live-session bearer token as
/// a query item (see ``LiveGameEndpoint``) -- never logged or persisted.
struct GameSocketTransportError: Error, Sendable, Equatable {}

/// Why establishing a new ``GameSocketConnection`` failed.
enum GameSocketConnectError: Error, Sendable, Equatable {
    /// The server responded to the upgrade request with a non-101 HTTP status
    /// (the backend rejects an invalid/expired token this way, before ever
    /// upgrading the connection -- see this type's construction site for the exact
    /// backend behavior this models). The numeric status is non-secret.
    case http(status: Int)
    /// A transport-level failure before any HTTP response was ever received
    /// (network unreachable, DNS failure, TLS error, timeout). Carries no
    /// diagnostic text, for the same reason as ``GameSocketTransportError``.
    case transport
}

/// A narrow, injectable abstraction over one open WebSocket connection.
///
/// Production conformance: ``URLSessionGameSocketConnection``, backed by a single
/// `URLSessionWebSocketTask`. Tests inject a deterministic, gate-driven fake so
/// reconnect/backoff/decode/cancellation handling can be exercised without real
/// network I/O.
///
/// A conformance must serialize its own frames: `nextEvent()` is never called
/// concurrently by this package's production caller (`AppModel+LiveGameSession.swift`
/// runs exactly one receive loop per connection, one frame at a time), and this
/// protocol places no ordering burden on a conformance beyond returning frames in the
/// order they actually arrived.
protocol GameSocketConnection: Sendable {
    /// Suspends until the next frame arrives, the connection closes cleanly, or the
    /// connection is lost.
    ///
    /// - Throws: ``GameSocketTransportError`` on an unclean loss, or
    ///   `CancellationError` when the calling task is cancelled (a conformance need
    ///   not itself observe cancellation; production callers race this with
    ///   `withTaskCancellationHandler`, whose `onCancel` closure calls ``close(code:reason:)``
    ///   to interrupt an in-flight receive promptly).
    func nextEvent() async throws -> GameSocketEvent

    /// Closes this connection, if it is not already closed. Synchronous (never
    /// `async`) so it may be called directly from a non-async `onCancel` closure.
    /// Idempotent: safe to call more than once, and safe to call after the
    /// connection has already closed on its own.
    func close(code: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

/// A narrow, injectable factory for establishing a new ``GameSocketConnection``.
///
/// Production conformance: ``URLSessionGameSocketFactory``. `url` always already
/// carries this attempt's bearer token as a query item (see ``LiveGameEndpoint``);
/// a conformance must never log or persist it.
protocol GameSocketFactory: Sendable {
    /// Establishes a new connection to `url`, suspending until the WebSocket upgrade
    /// either succeeds or definitively fails.
    ///
    /// - Throws: ``GameSocketConnectError``, or rethrows `CancellationError`.
    func connect(to url: URL) async throws -> any GameSocketConnection
}
