@testable import ArkhamHorrorShared
import Foundation
import Testing

// MARK: - Test doubles shared by AppModel test files

struct TestFailure: Error, Sendable {}

/// An in-memory ``ServerProfileStore`` whose reads and writes can be scripted to throw,
/// so startup storage handling can be exercised deterministically.
final class FakeServerProfileStore: ServerProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var profiles: [ServerProfile]
    private var selectedID: UUID?
    private var loadProfilesError: (any Error)?
    private var loadSelectionError: (any Error)?
    private var saveProfilesError: (any Error)?
    private var saveSelectionError: (any Error)?
    private(set) var saveProfilesCallCount = 0
    private(set) var saveSelectionCallCount = 0

    init(
        profiles: [ServerProfile] = [],
        selectedID: UUID? = nil,
        loadProfilesError: (any Error)? = nil,
        loadSelectionError: (any Error)? = nil,
        saveProfilesError: (any Error)? = nil,
        saveSelectionError: (any Error)? = nil
    ) {
        self.profiles = profiles
        self.selectedID = selectedID
        self.loadProfilesError = loadProfilesError
        self.loadSelectionError = loadSelectionError
        self.saveProfilesError = saveProfilesError
        self.saveSelectionError = saveSelectionError
    }

    func loadProfiles() throws -> [ServerProfile] {
        lock.lock()
        defer { lock.unlock() }
        if let loadProfilesError {
            throw loadProfilesError
        }
        return profiles
    }

    func saveProfiles(_ profiles: [ServerProfile]) throws {
        lock.lock()
        defer { lock.unlock() }
        if let saveProfilesError {
            throw saveProfilesError
        }
        saveProfilesCallCount += 1
        self.profiles = profiles
    }

    func loadSelectedProfileID() throws -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        if let loadSelectionError {
            throw loadSelectionError
        }
        return selectedID
    }

    func saveSelectedProfileID(_ id: UUID?) throws {
        lock.lock()
        defer { lock.unlock() }
        if let saveSelectionError {
            throw saveSelectionError
        }
        saveSelectionCallCount += 1
        selectedID = id
    }

    func snapshotProfiles() -> [ServerProfile] {
        lock.lock()
        defer { lock.unlock() }
        return profiles
    }

    func snapshotSelectedID() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return selectedID
    }
}

/// An in-memory ``TokenStore`` whose operations can be scripted to throw, with call
/// counts so tests can assert whether a token was retained, saved, or deleted.
actor FakeTokenStore: TokenStore {
    private var tokens: [UUID: String]
    private var readError: (any Error)?
    private var saveError: (any Error)?
    private var deleteError: (any Error)?
    private(set) var saveCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var lastSavedToken: String?

    init(tokens: [UUID: String] = [:]) {
        self.tokens = tokens
    }

    func setReadError(_ error: (any Error)?) {
        readError = error
    }

    func setSaveError(_ error: (any Error)?) {
        saveError = error
    }

    func setDeleteError(_ error: (any Error)?) {
        deleteError = error
    }

    func token(for profileID: UUID) async throws -> String? {
        if let readError {
            throw readError
        }
        return tokens[profileID]
    }

    func save(_ token: String, for profileID: UUID) async throws {
        if let saveError {
            throw saveError
        }
        saveCallCount += 1
        lastSavedToken = token
        tokens[profileID] = token
    }

    func deleteToken(for profileID: UUID) async throws {
        if let deleteError {
            throw deleteError
        }
        deleteCallCount += 1
        tokens[profileID] = nil
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

// MARK: - Fixtures

extension CurrentUser {
    static let sample = CurrentUser(
        username: "ashcan",
        email: "ashcan@example.com",
        beta: false,
        admin: false
    )
}

/// A valid custom (self-hosted) profile fixture. Constructed via a closure rather than
/// `try!` so a malformed literal fails loudly with a clear message instead of tripping a
/// force-try lint violation.
let sampleCustomProfile: ServerProfile = {
    do {
        return try ServerProfile.custom(
            displayName: "Self-hosted",
            rawURL: "https://self-hosted.example.com"
        )
    } catch {
        fatalError("sampleCustomProfile fixture must be a valid custom profile: \(error)")
    }
}()
