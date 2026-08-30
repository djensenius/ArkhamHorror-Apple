import Foundation

/// A subscribed game's in-flight live-session runner task and current attempt
/// identity, keyed by ``GameID`` in ``AppModel/liveGameSessions``.
///
/// `attemptID` mirrors ``AppModel/gameLifecycleActionAttempts``'s per-``GameID``
/// staleness pattern: every mutation the session runner
/// (`AppModel+LiveGameSession.swift`) makes to ``AppModel/liveGameStates`` first
/// checks that its own captured `attemptID` still matches
/// `liveGameSessions[gameID]?.attemptID`, so a superseded session's stale
/// await/frame/retry/error can never publish state, and cancelling+replacing a
/// session (``AppModel/startLiveGameSession(_:)``) is race-safe without needing to
/// await the old task's teardown first.
struct LiveGameSessionHandle: Sendable {
    let attemptID: UUID
    let task: Task<Void, Never>
}

/// Public live-game subscription/state API, bound to `AppModel`'s existing single
/// session/token authority exactly like every other game-lifecycle operation (see
/// `AppModel+GameLifecycle.swift`).
///
/// ## Ownership model
///
/// One live session exists per ``GameID`` at a time, reference-counted by
/// subscription (``liveGameViewers``): calling ``subscribeToLiveGame(_:)`` from
/// *any* scene/view showing that game increments its viewer set, starting a new
/// session only if none is already running; ``unsubscribeFromLiveGame(_:)``
/// decrements it, tearing the session down only once the last viewer has gone.
/// This makes two windows (or a `LiveGameView` plus some future secondary
/// presentation) showing the *same* game on macOS/iPadOS/visionOS share exactly one
/// socket/REST session and one published ``LiveGameState`` -- never duplicate
/// sessions racing each other, and never one scene's `onDisappear` tearing down a
/// session a sibling scene is still actively watching. Foreground/background is
/// handled by treating a backgrounded scene exactly like a temporarily-disappeared
/// view: both simply withdraw that scene's subscription via the same
/// ``LiveGameSubscriptionPolicy`` the view already uses for `onAppear`/`onDisappear`,
/// so backgrounding one scene while a sibling remains active never interrupts the
/// still-visible scene's session (see `LiveGameView`).
///
/// `AppModel` is shared process-wide across every window (see ``RootView``), so
/// ``liveGameStates``/``liveGameViewers``/``liveGameSessions`` are likewise
/// process-wide: this is the single live-game authority for the entire process,
/// mirroring every other `AppModel` state property.
extension AppModel {
    /// `id`'s current live-session presentation state, or ``LiveGameState/idle`` if
    /// no subscription has ever been created for it.
    func liveGameState(for id: GameID) -> LiveGameState {
        liveGameStates[id] ?? .idle
    }

    /// Registers a new viewer for `id`'s live game, starting its session if this is
    /// the first (or only remaining) subscriber. Always succeeds and always returns
    /// a token, even when not currently signed in -- in that case the session
    /// immediately (and only) publishes ``LiveGameState/authenticationExpired``,
    /// exactly matching how every other authenticated surface in this package
    /// behaves when reached outside a signed-in session, rather than the caller
    /// having to separately special-case "not signed in" before ever subscribing.
    ///
    /// The returned token must be passed back to ``unsubscribeFromLiveGame(_:)``
    /// exactly once, typically from a view's `onDisappear` (and, per
    /// ``LiveGameSubscriptionPolicy``, its scene-phase transitions).
    @discardableResult
    func subscribeToLiveGame(_ id: GameID) -> LiveGameSubscriptionToken {
        let token = LiveGameSubscriptionToken.issue(for: id)
        liveGameViewers[id, default: []].insert(token.subscriptionID)
        if liveGameSessions[id] == nil {
            startLiveGameSession(id)
        }
        return token
    }

    /// Withdraws `token`'s viewer registration, tearing down `token.gameID`'s live
    /// session (cancelling its task and closing its socket) once no viewer remains.
    /// Idempotent: unsubscribing an already-withdrawn (or never-subscribed) token is
    /// a no-op.
    ///
    /// This full teardown preserves any last known projection (published as
    /// ``LiveGameState/reconnecting(lastKnown:)`` rather than wiping the state to
    /// `nil`/``LiveGameState/idle``): a later ``subscribeToLiveGame(_:)`` for the
    /// same game (a new scene appearing, or this same scene reappearing) then
    /// restarts from that preserved board instead of a blank spinner, exactly
    /// mirroring how an unexpected socket loss already keeps the last known board on
    /// screen while reconnecting -- an *intentional* teardown/restart should look no
    /// different to the user than an involuntary one. See
    /// ``AppModel/startLiveGameSession(_:)`` for the corresponding restart-side read
    /// of this preserved projection.
    func unsubscribeFromLiveGame(_ token: LiveGameSubscriptionToken) {
        guard var viewers = liveGameViewers[token.gameID] else { return }
        viewers.remove(token.subscriptionID)
        if viewers.isEmpty {
            liveGameViewers[token.gameID] = nil
            stopLiveGameSession(token.gameID)
        } else {
            liveGameViewers[token.gameID] = viewers
        }
    }

    /// Explicitly restarts `id`'s live session from ``LiveGameState/loading`` after
    /// automatic reconnect was exhausted, a contract-incompatible payload was
    /// received, or a non-authentication terminal failure occurred -- the three
    /// states ``LiveGameState/isRetryable`` reports `true` for. A no-op for any
    /// other state (including ``LiveGameState/authenticationExpired``, which
    /// requires signing in again rather than merely retrying the same rejected
    /// token) or when `id` currently has no viewer at all (defensive; the only
    /// caller is a subscribed `LiveGameView`'s own retry action).
    func retryLiveGame(_ id: GameID) {
        guard liveGameState(for: id).isRetryable else { return }
        guard let viewers = liveGameViewers[id], !viewers.isEmpty else { return }
        startLiveGameSession(id)
    }

    /// Cancels and clears every live-game session and their published state,
    /// regardless of how many viewers any of them had. Called from
    /// ``resetGameLifecycleState()`` -- the single existing choke point already
    /// invoked by sign-out, profile switch, and 401 session-expiry handling -- so a
    /// live game's socket is always closed and its state cleared at exactly the same
    /// moments every other authenticated game-lifecycle/lobby state already is,
    /// without needing a second call site added to each of those three flows
    /// individually. A stale subscription (one whose view has not yet called
    /// ``unsubscribeFromLiveGame(_:)``) is simply dropped along with everything
    /// else: that view's own next `onDisappear`/scene-phase-driven unsubscribe is
    /// already unconditionally safe to call against a game with no session or
    /// viewer entry at all (see this function's callers' idempotence guarantees).
    func resetLiveGameState() {
        for handle in liveGameSessions.values {
            handle.task.cancel()
        }
        liveGameSessions = [:]
        liveGameViewers = [:]
        liveGameStates = [:]
    }
}
