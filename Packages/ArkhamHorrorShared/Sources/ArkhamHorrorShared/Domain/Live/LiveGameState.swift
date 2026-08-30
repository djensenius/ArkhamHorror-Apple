import Foundation

/// The typed presentation state of one game's live REST/WebSocket synchronization
/// session, keyed by ``GameID`` in ``AppModel/liveGameStates``.
///
/// Every case that can occur *after* the board has been shown at least once carries
/// `lastKnown: BoardProjection?` so the native board can stay visible (with an
/// overlay banner) through a transient reconnect/offline/incompatible-payload
/// condition instead of flashing back to a blank loading screen -- the backend
/// remains authoritative and this client never synthesizes or guesses at state that
/// was never actually received, so `lastKnown` is always either `nil` (nothing has
/// ever been received) or an exact, previously-published projection.
///
/// This type is pure and side-effect-free: it carries no task, socket, or token, and
/// its cases are driven exclusively by `AppModel+LiveGameSession.swift`.
enum LiveGameState: Equatable, Sendable {
    /// No live session has ever been started for this game (or one was fully torn
    /// down, e.g. every viewer unsubscribed). ``AppModel/subscribeToLiveGame(_:)``
    /// moves straight from this to ``loading``.
    case idle
    /// The first authoritative REST snapshot is in flight and nothing has ever been
    /// shown yet.
    case loading
    /// A live board is being shown, kept current either by the initial REST fetch or
    /// by a subsequently decoded WebSocket `GameUpdate` frame.
    case live(BoardProjection)
    /// The socket connection was lost (or has not yet been established) and this
    /// session is automatically retrying with bounded backoff; see
    /// ``LiveGameReconnectPolicy``. Recoverable without user action.
    case reconnecting(lastKnown: BoardProjection?)
    /// Automatic reconnect attempts were exhausted (or a token/transport failure
    /// occurred before ever going live). Recoverable only via an explicit
    /// ``AppModel/retryLiveGame(_:)`` call, so the app can never spin on a retry
    /// storm indefinitely in the background.
    case offline(lastKnown: BoardProjection?)
    /// A REST or WebSocket payload that this client build was required to decode
    /// (the game snapshot itself, never an out-of-scope `ServerMessage` tag this
    /// slice intentionally ignores -- see ``BoardSnapshotUpdate``) failed to decode
    /// through ``ContractJSON``. This is a genuine contract mismatch that reconnecting
    /// cannot fix; the user must update the app. Never a silent no-op.
    case incompatiblePayload(lastKnown: BoardProjection?)
    /// The authenticated session's token was rejected or found missing (HTTP 401, or
    /// an explicit WebSocket-handshake 401). `AppModel.handleGameLifecycleSessionExpired`
    /// has already been routed through, exactly like every other authenticated
    /// endpoint's 401 handling; this game screen has nothing further to retry on its
    /// own.
    case authenticationExpired
    /// An unrecoverable, non-authentication failure (an unexpected HTTP status, or a
    /// defensive/should-be-unreachable request-construction failure). Reuses
    /// ``GameLifecycleError`` rather than a second, parallel error vocabulary.
    case terminalFailure(GameLifecycleError, lastKnown: BoardProjection?)
}

extension LiveGameState {
    /// The most recently known board projection, if any -- either the currently live
    /// one or the last one shown before a reconnect/offline/incompatible condition.
    /// `nil` for ``idle``, ``loading``, ``authenticationExpired``, and any case that
    /// has never actually received a projection.
    var lastKnownProjection: BoardProjection? {
        switch self {
        case .idle, .loading, .authenticationExpired:
            nil
        case let .live(projection):
            projection
        case let .reconnecting(lastKnown),
             let .offline(lastKnown),
             let .incompatiblePayload(lastKnown):
            lastKnown
        case let .terminalFailure(_, lastKnown):
            lastKnown
        }
    }

    /// Whether ``AppModel/retryLiveGame(_:)`` is a meaningful action from this state.
    /// `authenticationExpired` is deliberately excluded: retrying would immediately
    /// repeat the same rejected token round-trip rather than accomplish anything: the
    /// user must sign in again first. `incompatiblePayload` is also deliberately
    /// excluded: per this case's own documentation, a decode failure is a genuine
    /// contract mismatch that reconnecting/refetching cannot fix (retrying would
    /// only reproduce the same failure against the same still-incompatible payload
    /// shape), so the only meaningful action from here is dismissing until the app
    /// is updated.
    var isRetryable: Bool {
        switch self {
        case .offline, .terminalFailure:
            true
        case .idle, .loading, .live, .reconnecting, .incompatiblePayload, .authenticationExpired:
            false
        }
    }
}
