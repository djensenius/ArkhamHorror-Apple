@testable import ArkhamHorrorShared
import Foundation
import Testing

// MARK: - Scripted/gated test doubles shared by AppModel test files

//
// Split out of `AppModelTestSupport.swift` purely by file size; grouped together here
// because every type below is a fully scriptable (rather than merely storage-backed)
// fake: its return values, thrown errors, and/or suspension points are configured
// per-test.

/// An in-memory ``TokenCleanupPendingStore`` whose reads/writes can be scripted to
/// throw, so durable cleanup-tombstone handling can be exercised deterministically
/// without ever touching the real Keychain that the production
/// ``KeychainTokenCleanupPendingStore`` default uses.
final class FakeTokenCleanupPendingStore: TokenCleanupPendingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID>
    private var pendingReadError: (any Error)?
    private var markError: (any Error)?
    private var clearError: (any Error)?

    init(ids: Set<UUID> = []) {
        self.ids = ids
    }

    func pendingProfileIDs() throws -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        if let pendingReadError {
            throw pendingReadError
        }
        return ids
    }

    func markPending(_ profileID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        if let markError {
            throw markError
        }
        ids.insert(profileID)
    }

    func clearPending(_ profileID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        if let clearError {
            throw clearError
        }
        ids.remove(profileID)
    }

    func clearAll() throws {
        lock.lock()
        defer { lock.unlock() }
        if let clearError {
            throw clearError
        }
        ids.removeAll()
    }

    /// Scripts (or clears, when `nil`) the error thrown by a subsequent
    /// ``pendingProfileIDs()`` call.
    func setPendingReadError(_ error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        pendingReadError = error
    }

    /// Scripts (or clears, when `nil`) the error thrown by a subsequent
    /// ``markPending(_:)`` call.
    func setMarkError(_ error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        markError = error
    }

    /// Scripts (or clears, when `nil`) the error thrown by a subsequent
    /// ``clearPending(_:)``/``clearAll()`` call.
    func setClearError(_ error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        clearError = error
    }

    /// The current pending-ID snapshot, independent of any scripted read error.
    func snapshotPendingIDs() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

/// A ``CapabilityProbing`` fake that returns a fixed outcome or throws a fixed error.
actor ScriptedCapabilityProbe: CapabilityProbing {
    enum Script {
        case outcome(CompatibilityOutcome)
        case failure(any Error & Sendable)
    }

    private let script: Script
    private(set) var callCount = 0
    private(set) var lastProbedProfileID: UUID?

    init(_ script: Script) {
        self.script = script
    }

    func probe(_ profile: ServerProfile) async throws -> CompatibilityOutcome {
        callCount += 1
        lastProbedProfileID = profile.id
        switch script {
        case let .outcome(outcome):
            return outcome
        case let .failure(error):
            throw error
        }
    }
}

/// A ``CapabilityProbing`` fake that suspends every call on a FIFO queue of checked
/// continuations until the test explicitly resumes it, ignoring outer task cancellation
/// (as an injected dependency that does not itself observe cancellation would).
actor GatedCapabilityProbe: CapabilityProbing {
    private var continuations: [CheckedContinuation<CompatibilityOutcome, any Error>] = []
    private var pendingWaiters: [(
        threshold: Int, continuation: CheckedContinuation<Void, Never>
    )] = []
    private(set) var callCount = 0

    func probe(_: ServerProfile) async throws -> CompatibilityOutcome {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            notifyWaiters()
        }
    }

    private func notifyWaiters() {
        pendingWaiters.removeAll { entry in
            guard continuations.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }

    /// Suspends until at least `count` probe calls are simultaneously pending.
    func waitUntilPending(_ count: Int) async {
        if continuations.count >= count {
            return
        }
        await withCheckedContinuation { pendingWaiters.append((count, $0)) }
    }

    /// Resumes the oldest (first-issued) still-pending call with `outcome`.
    func resumeOldest(with outcome: CompatibilityOutcome) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: outcome)
    }

    /// Resumes the newest (most recently issued) still-pending call with `outcome`.
    func resumeNewest(with outcome: CompatibilityOutcome) {
        guard !continuations.isEmpty else { return }
        continuations.removeLast().resume(returning: outcome)
    }
}

/// An ``AppAuthenticating`` fake whose `authenticate`/`register`/`currentUser` results
/// are individually scriptable, and whose call order is recorded so tests can assert
/// validate-before-save ordering.
actor ScriptedAuthenticating: AppAuthenticating {
    enum TokenResult {
        case success(AuthToken)
        case failure(any Error & Sendable)
    }

    enum UserResult {
        case success(CurrentUser)
        case failure(any Error & Sendable)
    }

    private var authenticateResult: TokenResult
    private var registerResult: TokenResult
    private var currentUserResult: UserResult
    private(set) var callOrder: [String] = []
    private(set) var lastCurrentUserToken: String?

    init(
        authenticateResult: TokenResult = .failure(TestFailure()),
        registerResult: TokenResult = .failure(TestFailure()),
        currentUserResult: UserResult = .failure(TestFailure())
    ) {
        self.authenticateResult = authenticateResult
        self.registerResult = registerResult
        self.currentUserResult = currentUserResult
    }

    func setCurrentUserResult(_ result: UserResult) {
        currentUserResult = result
    }

    func authenticate(_: AuthenticationCredentials, on _: ServerProfile) async throws -> AuthToken {
        callOrder.append("authenticate")
        switch authenticateResult {
        case let .success(token):
            return token
        case let .failure(error):
            throw error
        }
    }

    func register(_: RegistrationDetails, on _: ServerProfile) async throws -> AuthToken {
        callOrder.append("register")
        switch registerResult {
        case let .success(token):
            return token
        case let .failure(error):
            throw error
        }
    }

    func currentUser(on _: ServerProfile, token: String) async throws -> CurrentUser {
        callOrder.append("currentUser")
        lastCurrentUserToken = token
        switch currentUserResult {
        case let .success(user):
            return user
        case let .failure(error):
            throw error
        }
    }
}
