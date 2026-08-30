@testable import ArkhamHorrorShared
import Foundation
import Testing

// MARK: - Deterministic, gate-driven test doubles for the live-game session runner

/// One scriptable outcome a ``FakeGameSocketConnection/nextEvent()`` call resolves
/// with: a frame, a network-loss throw, or (mirroring the real
/// `URLSessionWebSocketTask`) a `CancellationError` rethrow.
enum FakeGameSocketEventOutcome: Sendable {
    case event(GameSocketEvent)
    case failure(any Error)
}

/// A deterministic, gate-driven ``GameSocketConnection`` fake.
///
/// An `actor` (rather than a lock-protected class) for every isolated-state method,
/// with exactly one `nonisolated` escape hatch: ``close(code:reason:)``, whose
/// protocol contract requires it be callable synchronously from a non-async
/// `onCancel` closure (see ``GameSocketConnection/close(code:reason:)``'s own
/// documentation). That method bridges to actor-isolated state via `Task { ... }`,
/// exactly mirroring how the production ``URLSessionGameSocketConnection``'s
/// `close(code:reason:)` similarly triggers an asynchronous
/// `URLSessionWebSocketTask.cancel(with:reason:)` under the hood rather than
/// synchronously unblocking an in-flight `receive()` -- so a test that needs to
/// observe this connection having actually closed awaits ``waitUntilClosed(count:)``
/// (a real continuation-based gate) rather than a `Task.yield()`.
actor FakeGameSocketConnection: GameSocketConnection {
    private var queue: [FakeGameSocketEventOutcome] = []
    private var pendingContinuation: CheckedContinuation<GameSocketEvent, any Error>?
    private var awaitingWaiters: [CheckedContinuation<Void, Never>] = []
    private var isClosed = false
    private(set) var closeCallCount = 0
    private(set) var closeCodes: [URLSessionWebSocketTask.CloseCode] = []
    private var closeWaiters: [
        (threshold: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    /// Enqueues an outcome for a future ``nextEvent()`` call (FIFO), or immediately
    /// resumes an already in-flight ``nextEvent()`` call if one is currently
    /// suspended awaiting one.
    func enqueue(_ outcome: FakeGameSocketEventOutcome) {
        if let continuation = pendingContinuation {
            pendingContinuation = nil
            resume(continuation, with: outcome)
            return
        }
        queue.append(outcome)
    }

    /// Suspends until ``nextEvent()`` is actually in flight and suspended awaiting a
    /// result -- lets a test observe the receive loop having reached its blocking
    /// point before injecting a loss/close/cancellation, instead of guessing with
    /// `Task.yield()`.
    func waitUntilAwaitingNextEvent() async {
        if pendingContinuation != nil {
            return
        }
        await withCheckedContinuation { awaitingWaiters.append($0) }
    }

    /// Suspends until ``close(code:reason:)`` has actually been processed at least
    /// `count` times (default `1`).
    func waitUntilClosed(count: Int = 1) async {
        if closeCallCount >= count {
            return
        }
        await withCheckedContinuation { closeWaiters.append((count, $0)) }
    }

    nonisolated func close(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { await performClose(code: code, reason: reason) }
    }

    private func performClose(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        closeCallCount += 1
        closeCodes.append(code)
        notifyCloseWaiters()
        guard !isClosed else { return }
        isClosed = true
        if let continuation = pendingContinuation {
            pendingContinuation = nil
            continuation.resume(returning: .closed(code: code, reason: reason))
        }
    }

    func nextEvent() async throws -> GameSocketEvent {
        if !queue.isEmpty {
            let outcome = queue.removeFirst()
            return try resolve(outcome)
        }
        if isClosed {
            throw GameSocketTransportError()
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation
            let waiters = awaitingWaiters
            awaitingWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private func resolve(_ outcome: FakeGameSocketEventOutcome) throws -> GameSocketEvent {
        switch outcome {
        case let .event(event): return event
        case let .failure(error): throw error
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<GameSocketEvent, any Error>,
        with outcome: FakeGameSocketEventOutcome
    ) {
        switch outcome {
        case let .event(event): continuation.resume(returning: event)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    private func notifyCloseWaiters() {
        closeWaiters.removeAll { entry in
            guard closeCallCount >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }
}

/// A deterministic, gate-driven ``GameSocketFactory`` fake, mirroring
/// ``ScriptedGameLifecycleService``'s `getGame` gating pattern exactly (queued
/// results, or a fully gated mode a test drives one connect attempt at a time via
/// ``waitUntilConnectPending(_:)``/``resumeOldestConnect(with:)``).
actor FakeGameSocketFactory: GameSocketFactory {
    private var connectQueue: [Result<any GameSocketConnection, any Error>] = []
    private var isGated = false
    private var connectContinuations: [
        CheckedContinuation<any GameSocketConnection, any Error>
    ] = []
    private var connectPendingWaiters: [
        (threshold: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private(set) var connectCallCount = 0
    private(set) var connectedURLs: [URL] = []

    func enqueueConnectResult(_ result: Result<any GameSocketConnection, any Error>) {
        connectQueue.append(result)
    }

    func setGated(_ gated: Bool) {
        isGated = gated
    }

    /// Suspends until at least `count` `connect(to:)` calls are simultaneously
    /// pending (only meaningful once ``setGated(_:)`` is `true`).
    func waitUntilConnectPending(_ count: Int) async {
        if connectContinuations.count >= count {
            return
        }
        await withCheckedContinuation { connectPendingWaiters.append((count, $0)) }
    }

    /// Resumes the oldest (first-issued) still-pending `connect(to:)` call.
    func resumeOldestConnect(with result: Result<any GameSocketConnection, any Error>) {
        guard !connectContinuations.isEmpty else { return }
        let continuation = connectContinuations.removeFirst()
        switch result {
        case let .success(value): continuation.resume(returning: value)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    func connect(to url: URL) async throws -> any GameSocketConnection {
        connectCallCount += 1
        connectedURLs.append(url)
        if isGated {
            return try await withCheckedThrowingContinuation { continuation in
                connectContinuations.append(continuation)
                notifyConnectWaiters()
            }
        }
        guard !connectQueue.isEmpty else { throw TestFailure() }
        return try connectQueue.removeFirst().get()
    }

    private func notifyConnectWaiters() {
        connectPendingWaiters.removeAll { entry in
            guard connectContinuations.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }
}

/// A deterministic, gate-driven ``LiveGameClock`` fake.
///
/// Records every requested ``Duration`` (so a test can assert jitter-bounded backoff
/// delays without ever actually waiting for them), and defaults to completing every
/// `sleep(for:)` call immediately so untimed tests run instantly; ``setGated(_:)``
/// switches to holding each call open until explicitly resumed, for tests that need
/// to observe a reconnect specifically mid-backoff-sleep (e.g. to prove cancellation
/// during backoff is honored).
actor FakeLiveGameClock: LiveGameClock {
    private(set) var requestedDurations: [Duration] = []
    private var isGated = false
    private var sleepContinuations: [CheckedContinuation<Void, any Error>] = []
    private var sleepPendingWaiters: [
        (threshold: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func setGated(_ gated: Bool) {
        isGated = gated
    }

    func waitUntilSleepPending(_ count: Int) async {
        if sleepContinuations.count >= count {
            return
        }
        await withCheckedContinuation { sleepPendingWaiters.append((count, $0)) }
    }

    func resumeOldestSleep(throwing error: (any Error)? = nil) {
        guard !sleepContinuations.isEmpty else { return }
        let continuation = sleepContinuations.removeFirst()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func sleep(for duration: Duration) async throws {
        requestedDurations.append(duration)
        guard isGated else { return }
        try await withCheckedThrowingContinuation { continuation in
            sleepContinuations.append(continuation)
            notifySleepWaiters()
        }
    }

    private func notifySleepWaiters() {
        sleepPendingWaiters.removeAll { entry in
            guard sleepContinuations.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }
}

/// A deterministic ``LiveGameRandomSource`` fake returning a scripted sequence of
/// unit-interval values (repeating its last value once exhausted, by default, so a
/// test need not predict exactly how many reconnect attempts will consume it). A
/// lock-protected class (not an `actor`) because ``nextUnitInterval()`` is a plain
/// synchronous, non-throwing protocol requirement -- mirroring
/// ``FakeServerProfileStore``'s synchronous-protocol lock pattern.
final class FakeLiveGameRandomSource: LiveGameRandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double]

    init(values: [Double]) {
        precondition(!values.isEmpty, "FakeLiveGameRandomSource requires at least one value")
        self.values = values
    }

    func nextUnitInterval() -> Double {
        lock.lock()
        defer { lock.unlock() }
        if values.count > 1 {
            return values.removeFirst()
        }
        return values[0]
    }
}
