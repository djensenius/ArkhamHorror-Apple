@testable import ArkhamHorrorShared
import Foundation

// MARK: - Gated fakes for token-mutation race coverage

/// A durable token-store mutation gated by ``GatedTokenStore``, identifying which
/// profile and (for a save) which token a suspended call is waiting to apply.
enum GatedTokenMutation: Hashable, Sendable {
    case save(token: String, profileID: UUID)
    case delete(profileID: UUID)
    case deleteAll
}

/// A ``TokenStore`` fake whose `save`/`deleteToken` calls each suspend on a FIFO queue
/// of checked continuations until the test explicitly resumes them, ignoring outer task
/// cancellation (as an injected dependency that does not itself observe cancellation
/// would). `token(for:)` reads are unscripted, instantaneous passthroughs against the
/// current underlying storage, so a test can observe whether a still-pending mutation
/// has (or has not yet) taken effect.
actor GatedTokenStore: TokenStore {
    private var tokens: [UUID: String]
    private var pending: [(
        mutation: GatedTokenMutation, continuation: CheckedContinuation<Void, any Error>
    )] = []
    private var pendingWaiters: [(
        threshold: Int, continuation: CheckedContinuation<Void, Never>
    )] = []
    private var postApplyPending: [(
        mutation: GatedTokenMutation, continuation: CheckedContinuation<Void, Never>
    )] = []
    private var postApplyWaiters: [(
        threshold: Int, continuation: CheckedContinuation<Void, Never>
    )] = []
    private(set) var saveCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var deleteAllCallCount = 0

    /// When `true`, `save`/`deleteToken` suspend a *second* time — after the durable
    /// mutation has already been applied to `tokens`, but before returning control to
    /// the caller — modeling the narrow window where a write has already taken
    /// effect but the awaiting call site has not yet resumed. `false` (the default)
    /// preserves every existing single-suspension test's behavior unchanged.
    private var suspendAfterApply = false

    func setSuspendAfterApply(_ value: Bool) {
        suspendAfterApply = value
    }

    init(tokens: [UUID: String] = [:]) {
        self.tokens = tokens
    }

    func token(for profileID: UUID) async throws -> String? {
        tokens[profileID]
    }

    func save(_ token: String, for profileID: UUID) async throws {
        saveCallCount += 1
        try await suspend(.save(token: token, profileID: profileID))
        tokens[profileID] = token
        if suspendAfterApply {
            await suspendPostApply(.save(token: token, profileID: profileID))
        }
    }

    func deleteToken(for profileID: UUID) async throws {
        deleteCallCount += 1
        try await suspend(.delete(profileID: profileID))
        tokens[profileID] = nil
        if suspendAfterApply {
            await suspendPostApply(.delete(profileID: profileID))
        }
    }

    func deleteAllTokens() async throws {
        deleteAllCallCount += 1
        try await suspend(.deleteAll)
        tokens.removeAll()
        if suspendAfterApply {
            await suspendPostApply(.deleteAll)
        }
    }

    /// The current storage snapshot, independent of any pending mutation.
    func snapshotTokens() -> [UUID: String] {
        tokens
    }

    private func suspend(_ mutation: GatedTokenMutation) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pending.append((mutation, continuation))
            notifyWaiters()
        }
    }

    private func suspendPostApply(_ mutation: GatedTokenMutation) async {
        await withCheckedContinuation { continuation in
            postApplyPending.append((mutation, continuation))
            notifyPostApplyWaiters()
        }
    }

    private func notifyWaiters() {
        pendingWaiters.removeAll { entry in
            guard pending.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }

    private func notifyPostApplyWaiters() {
        postApplyWaiters.removeAll { entry in
            guard postApplyPending.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }

    /// Suspends until at least `count` save/delete calls are simultaneously pending.
    func waitUntilPending(_ count: Int) async {
        if pending.count >= count {
            return
        }
        await withCheckedContinuation { pendingWaiters.append((count, $0)) }
    }

    /// Suspends until at least `count` save/delete calls are simultaneously suspended
    /// in the post-apply gate (only reachable when ``suspendAfterApply`` is `true`).
    func waitUntilPostApplyPending(_ count: Int) async {
        if postApplyPending.count >= count {
            return
        }
        await withCheckedContinuation { postApplyWaiters.append((count, $0)) }
    }

    /// The mutation each currently pending call is waiting to apply, oldest first.
    func pendingMutations() -> [GatedTokenMutation] {
        pending.map(\.mutation)
    }

    /// Resumes the oldest (first-issued) still-pending call, letting it apply, unless
    /// `error` is provided, in which case the call fails with `error` instead (and its
    /// mutation is not applied to `tokens`) — used to simulate a service-scoped
    /// `deleteAllTokens()` failure without disturbing the shared FIFO ordering used to
    /// test barrier/serialization behavior.
    func resumeOldest(throwing error: (any Error)? = nil) {
        guard !pending.isEmpty else { return }
        let entry = pending.removeFirst()
        if let error {
            entry.continuation.resume(throwing: error)
        } else {
            entry.continuation.resume()
        }
    }

    /// Resumes the newest (most recently issued) still-pending call, letting it apply.
    func resumeNewest() {
        guard !pending.isEmpty else { return }
        pending.removeLast().continuation.resume()
    }

    /// Resumes the oldest still-post-apply-suspended call, letting it return.
    func resumeOldestPostApply() {
        guard !postApplyPending.isEmpty else { return }
        postApplyPending.removeFirst().continuation.resume()
    }
}

/// An ``AppAuthenticating`` fake whose `currentUser` calls each suspend on a FIFO queue
/// of checked continuations until the test explicitly resumes them, ignoring outer task
/// cancellation (as an injected dependency that does not itself observe cancellation
/// would). `authenticate`/`register` are unscripted failures, since this fake exists
/// specifically to gate token-validation races rather than sign-in/registration ones.
actor GatedAuthenticating: AppAuthenticating {
    private var pending: [CheckedContinuation<CurrentUser, any Error>] = []
    private var pendingWaiters: [(
        threshold: Int, continuation: CheckedContinuation<Void, Never>
    )] = []
    private(set) var callCount = 0

    func authenticate(_: AuthenticationCredentials, on _: ServerProfile) async throws -> AuthToken {
        throw TestFailure()
    }

    func register(_: RegistrationDetails, on _: ServerProfile) async throws -> AuthToken {
        throw TestFailure()
    }

    func currentUser(on _: ServerProfile, token _: String) async throws -> CurrentUser {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
            notifyWaiters()
        }
    }

    private func notifyWaiters() {
        pendingWaiters.removeAll { entry in
            guard pending.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }

    /// Suspends until at least `count` `currentUser` calls are simultaneously pending.
    func waitUntilPending(_ count: Int) async {
        if pending.count >= count {
            return
        }
        await withCheckedContinuation { pendingWaiters.append((count, $0)) }
    }

    /// Resumes the oldest (first-issued) still-pending call with `result`.
    func resumeOldest(with result: Result<CurrentUser, any Error>) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(with: result)
    }

    /// Resumes the newest (most recently issued) still-pending call with `result`.
    func resumeNewest(with result: Result<CurrentUser, any Error>) {
        guard !pending.isEmpty else { return }
        pending.removeLast().resume(with: result)
    }
}

/// Deterministically observes admissions into `AppModel`'s per-profile
/// `serializedTokenAccess`/`enqueueCancellationCleanup` queues via
/// `AppModel.tokenAccessAdmissionHook`, so a test can await an exact admission count
/// for a profile — the enqueuing call having *synchronously* registered itself as the
/// new tail in `tokenAccessQueues` — instead of inferring scheduler progress with a
/// fixed number of `Task.yield()` calls, which cannot in general bound how many
/// asynchronous steps precede a given enqueue.
///
/// `record(_:)` (assigned as `AppModel.tokenAccessAdmissionHook`) is invoked
/// synchronously on the main actor by production code; `waitForAdmissions(_:of:)` is
/// awaited from a test's own (arbitrary) task. Both sides only ever touch `counts`/
/// `waiters` under `lock`, and every continuation is resumed exactly once, outside the
/// lock, so this is safe to use from either context without itself being an actor.
final class TokenAccessAdmissionCounter: @unchecked Sendable {
    private struct Waiter {
        let profileID: UUID
        let threshold: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var counts: [UUID: Int] = [:]
    private var waiters: [Waiter] = []

    /// The hook to assign to `AppModel.tokenAccessAdmissionHook`.
    var hook: @Sendable (UUID) -> Void {
        { [weak self] profileID in
            self?.record(profileID)
        }
    }

    private func record(_ profileID: UUID) {
        lock.lock()
        counts[profileID, default: 0] += 1
        let newCount = counts[profileID, default: 0]
        var readyContinuations: [CheckedContinuation<Void, Never>] = []
        waiters.removeAll { waiter in
            guard waiter.profileID == profileID, newCount >= waiter.threshold else {
                return false
            }
            readyContinuations.append(waiter.continuation)
            return true
        }
        lock.unlock()
        for continuation in readyContinuations {
            continuation.resume()
        }
    }

    /// Synchronous check, called only from non-`async` contexts (`waitForAdmissions`
    /// below never touches `lock` directly from its own `async` function body).
    private func currentCount(of profileID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[profileID, default: 0]
    }

    /// Registers `continuation` as a waiter for `count` admissions of `profileID`
    /// unless that count is already satisfied, in which case it resumes `continuation`
    /// immediately instead. Synchronous, so it may safely be called from the
    /// synchronous closure `withCheckedContinuation` hands to
    /// `waitForAdmissions(_:of:)` below without touching `lock` from an `async`
    /// function body.
    private func registerWaiterIfNeeded(
        count: Int, of profileID: UUID, continuation: CheckedContinuation<Void, Never>
    ) {
        lock.lock()
        if counts[profileID, default: 0] >= count {
            lock.unlock()
            continuation.resume()
            return
        }
        waiters.append(Waiter(profileID: profileID, threshold: count, continuation: continuation))
        lock.unlock()
    }

    /// Suspends until at least `count` admissions have been recorded for `profileID`.
    func waitForAdmissions(_ count: Int, of profileID: UUID) async {
        if currentCount(of: profileID) >= count {
            return
        }
        await withCheckedContinuation { continuation in
            registerWaiterIfNeeded(count: count, of: profileID, continuation: continuation)
        }
    }
}
