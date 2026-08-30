import Foundation

/// An injectable sleep primitive so reconnect backoff is deterministically testable.
///
/// Production conformance: ``SystemLiveGameClock`` (backed by `Task.sleep`). Tests
/// inject a gate-driven fake so a reconnect delay's *start* can be observed and its
/// *completion* controlled precisely, exactly like this codebase's existing
/// `AppModelGatedTestSupport.swift`/`GameLifecycleTestSupport.swift` gates control
/// other suspension points.
protocol LiveGameClock: Sendable {
    /// Suspends for `duration`, or throws `CancellationError` if the calling task is
    /// cancelled first.
    func sleep(for duration: Duration) async throws

    /// A monotonic instant, used only to measure elapsed ``Duration``s between two
    /// captured calls (never as a wall-clock/calendar value) -- specifically, the
    /// session runner's stable-connection criterion (see
    /// ``LiveGameReconnectPolicy/stableConnectionDuration``). `async` so an
    /// actor-isolated test fake can satisfy this requirement without any real
    /// waiting: a fake's `now()` simply returns its own synthetic, test-advanced
    /// instant rather than the real wall clock.
    func now() async -> ContinuousClock.Instant
}

/// The production ``LiveGameClock``, backed directly by `Task.sleep(for:)` and
/// `ContinuousClock`.
struct SystemLiveGameClock: LiveGameClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    func now() async -> ContinuousClock.Instant {
        ContinuousClock.now
    }
}

/// An injectable source of jitter randomness so reconnect backoff is deterministically
/// testable.
///
/// Production conformance: ``SystemLiveGameRandomSource``. Tests inject a fixed or
/// scripted source so a computed backoff delay's exact bounds can be asserted rather
/// than merely "is roughly right."
protocol LiveGameRandomSource: Sendable {
    /// Returns a value in `[0, 1)` used as this attempt's jitter fraction.
    func nextUnitInterval() -> Double
}

/// The production ``LiveGameRandomSource``, backed directly by `Double.random(in:)`.
struct SystemLiveGameRandomSource: LiveGameRandomSource {
    func nextUnitInterval() -> Double {
        Double.random(in: 0 ..< 1)
    }
}

/// Pure bounded-exponential-backoff-with-full-jitter arithmetic for automatic
/// WebSocket reconnect attempts.
///
/// Deliberately has no dependency on ``LiveGameClock``/``LiveGameRandomSource``: every
/// function here is a total, side-effect-free computation from its explicit
/// parameters, so a test can assert its exact bounds for any `(attempt,
/// unitInterval)` pair without any suspension, gate, or fake at all. The session
/// runner (`AppModel+LiveGameSession.swift`) is the only caller that combines this
/// with an actual clock/random source.
///
/// Uses "full jitter" (`delay = random(0, min(cap, base * 2^attempt))`), the
/// strategy AWS's well-known backoff-and-jitter guidance recommends to avoid
/// synchronized retry storms across many independent clients -- directly relevant
/// here given this backend's own documented retry-storm incident (see
/// `AppModel+LiveGameSession.swift`'s reconnect documentation).
enum LiveGameReconnectPolicy {
    /// The delay ceiling before any jitter is applied, for the very first automatic
    /// reconnect attempt (`attempt == 0`).
    static let initialDelayCeiling: Duration = .seconds(1)

    /// The maximum delay ceiling any attempt can reach, regardless of how large
    /// `attempt` grows.
    static let maximumDelayCeiling: Duration = .seconds(30)

    /// The number of consecutive automatic reconnect attempts (each following a full
    /// jittered backoff delay) permitted after an unexpected loss before this session
    /// gives up and transitions to `.offline`, surfacing an explicit,
    /// user-initiated ``AppModel/retryLiveGame(_:)`` action instead of continuing to
    /// retry unattended in the background -- the concrete bound that prevents this
    /// from ever becoming an unbounded retry storm.
    static let maximumAttempts = 6

    /// The minimum duration a connection must have stayed continuously open (from
    /// the moment its REST refetch published a fresh snapshot to the moment it was
    /// lost) before that loss resets ``AppModel/runLiveGameSession(_:)``'s own
    /// `reconnectAttempt` counter back to `0`.
    ///
    /// Without this, resetting the counter unconditionally after *any* successful
    /// handshake -- even one immediately followed by another close -- lets an
    /// accept-then-immediate-close flap (a backend/proxy "slow subscriber"
    /// disconnect storm, or any other pathological rapid connect/close cycle) loop
    /// forever at `reconnectAttempt == 0`, since every single attempt "succeeds"
    /// just long enough to reset the budget before failing again: this session
    /// would then never reach ``maximumAttempts`` and never transition to
    /// `.offline`, hammering the REST endpoint and socket handshake in an unbounded
    /// loop. Requiring a connection to have remained open for at least this long
    /// before its loss is treated as "the backoff budget is refreshed" ensures a
    /// flapping connection instead keeps accumulating attempts against the same
    /// bounded budget every ordinary reconnect loss does, reaching `.offline` in
    /// finite time exactly like any other repeated failure.
    ///
    /// An uptime-based (rather than frames-received-based) criterion is used
    /// deliberately: a legitimately quiet, long-lived game room the backend closes
    /// on its own idle timeout (already documented elsewhere in this file/package as
    /// routine, expected churn) may go its entire connected lifetime without ever
    /// receiving a single broadcast frame, and must still count as "stable" rather
    /// than being spuriously treated as a flap merely because it happened to be
    /// quiet.
    static let stableConnectionDuration: Duration = .seconds(10)

    /// The delay ceiling before jitter for the 0-based `attempt`'th automatic
    /// reconnect: doubles per attempt starting from ``initialDelayCeiling``, capped at
    /// ``maximumDelayCeiling``.
    static func delayCeiling(forAttempt attempt: Int) -> Duration {
        precondition(attempt >= 0, "attempt must be non-negative")
        // Capping the exponent (rather than the resulting duration) before the
        // multiply avoids ever constructing an enormous intermediate `Duration`;
        // 2^12 seconds (~68 minutes) already vastly exceeds `maximumDelayCeiling`,
        // so the subsequent `min` always wins once this cap does.
        let exponent = min(attempt, 12)
        let multiplier = 1 << exponent
        let scaled = initialDelayCeiling * multiplier
        return scaled < maximumDelayCeiling ? scaled : maximumDelayCeiling
    }

    /// The actual, jittered delay to sleep before the 0-based `attempt`'th automatic
    /// reconnect: a uniformly random duration in `[0, delayCeiling(forAttempt:)]`,
    /// using the supplied `unitInterval` (expected to be in `[0, 1)`; a value outside
    /// that range is clamped rather than trusted, so a misbehaving injected random
    /// source can never produce a negative or unbounded delay). Non-finite input
    /// (`.nan`, `.infinity`, `-.infinity`) is sanitized to `0` *before* clamping --
    /// `min`/`max` alone do not clamp `NaN` (IEEE 754 comparisons against `NaN` are
    /// always `false`, so it would otherwise propagate straight through into a
    /// non-finite `Duration`) -- so even a `NaN`-producing random source falls back
    /// to the safe minimum (no jitter) rather than an unbounded/undefined delay.
    static func jitteredDelay(forAttempt attempt: Int, unitInterval: Double) -> Duration {
        let ceiling = delayCeiling(forAttempt: attempt)
        let sanitizedUnitInterval = unitInterval.isFinite ? unitInterval : 0
        let clampedUnitInterval = min(max(sanitizedUnitInterval, 0), 1)
        let components = ceiling.components
        let ceilingSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1e18
        return .seconds(ceilingSeconds * clampedUnitInterval)
    }
}
