import Foundation
import Observation

struct TokenAccessTail {
    let id: UUID
    let task: Task<Void, Never>
}

/// The shared, `@MainActor` session coordinator for every Arkham Horror platform target.
///
/// On launch, `AppModel` loads persisted server profiles, seeds the canonical hosted
/// profile when needed, restores the selected profile, probes it for compatibility, and
/// restores any stored authentication token. It then exposes typed sign-in, registration,
/// sign-out, retry, and profile-selection operations. The implementation is split across
/// `AppModel+*.swift` files by concern (launch, compatibility, authentication and
/// sign-out, and profile selection); shared generation-guard and error-mapping helpers
/// are defined in an extension below.
///
/// Concurrency safety:
/// - Every mutation of ``sessionState``, ``operation``, ``operationFailure``, and
///   ``profiles`` happens on the main actor.
/// - A monotonically increasing `generation` counter is captured by every in-flight
///   task. Before any asynchronous completion mutates state, it checks that its captured
///   generation still matches the current one. Starting a new flow (launch, profile
///   switch, retry, or operation) cancels the previous task **and** advances the
///   generation, so a stale completion cannot mutate state even if an injected
///   dependency does not itself observe cancellation.
///
/// Secrets: passwords and registration details are passed through as local parameters
/// and are never stored as properties of this type; only a validated, durably saved
/// token ever backs a ``SessionState/signedIn(profile:compatibility:user:)`` state, and
/// even then only the typed, non-secret ``CurrentUser`` is exposed.
///
/// Access levels: most members below are internal (not `private`) rather than `public`,
/// so the implementation can be split across same-module `AppModel+*.swift` extension
/// files by concern and so deterministic tests can inspect and drive them via
/// `@testable import`. `AppModel` itself is not `public`, so none of this is part of any
/// public API surface.
@MainActor
@Observable
final class AppModel {
    /// The current launch/session state. Never contains a password or token.
    var sessionState: SessionState = .launching
    /// The in-flight sign-in, registration, or sign-out operation, if any.
    var operation: SessionOperation = .idle
    /// The most recent operation failure, cleared at the start of the next operation.
    var operationFailure: SessionOperationFailure?
    /// The persisted server profile list, including the canonical hosted profile.
    var profiles: [ServerProfile] = []
    /// The in-flight custom-profile add, edit, or remove operation, if any.
    var profileManagementOperation: ProfileManagementOperation = .idle
    /// The most recent profile-management failure, cleared at the start of the next one.
    var profileManagementFailure: ProfileManagementFailure?

    @ObservationIgnored let profileStore: any ServerProfileStore
    @ObservationIgnored let tokenStore: any TokenStore
    @ObservationIgnored let capabilityProbe: any CapabilityProbing
    @ObservationIgnored let authenticationSession: any AppAuthenticating

    @ObservationIgnored var selectedProfile: ServerProfile = .hosted
    @ObservationIgnored var generation = 0
    /// The in-flight launch/compatibility/token-restoration task, if any.
    @ObservationIgnored var flowTask: Task<Void, Never>?
    /// The in-flight sign-in/registration/sign-out operation task, if any.
    @ObservationIgnored var operationTask: Task<Void, Never>?
    /// The in-flight profile add/edit/remove task, if any.
    @ObservationIgnored var profileManagementTask: Task<Void, Never>?
    /// A monotonically increasing counter guarding stale profile-management
    /// completions, independent of ``generation`` since a profile edit/removal does
    /// not itself need to cancel or be cancelled by the launch/auth flow. See
    /// ``AppModel/isCurrentProfileOperation(_:)``.
    @ObservationIgnored var profileManagementGeneration = 0

    /// The tail of the per-profile serialized token-store access chain. See
    /// ``serializedTokenAccess(for:_:)``.
    @ObservationIgnored var tokenAccessQueues: [UUID: TokenAccessTail] = [:]

    init(
        profileStore: any ServerProfileStore = UserDefaultsServerProfileStore(),
        tokenStore: any TokenStore = KeychainTokenStore(),
        capabilityProbe: any CapabilityProbing = CapabilityProbe(),
        authenticationSession: any AppAuthenticating = AuthenticationSession()
    ) {
        self.profileStore = profileStore
        self.tokenStore = tokenStore
        self.capabilityProbe = capabilityProbe
        self.authenticationSession = authenticationSession
        startLaunchFlow()
    }
}

/// Shared helpers for generation-guarded state transitions and typed error mapping.
extension AppModel {
    func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }

    /// Whether `operationGeneration` (captured when a profile-management task started)
    /// still matches the current ``profileManagementGeneration``.
    func isCurrentProfileOperation(_ operationGeneration: Int) -> Bool {
        operationGeneration == profileManagementGeneration
    }

    /// Runs a synchronous storage read/write, transitioning to
    /// ``SessionState/storageCorrupted(_:)`` on failure.
    ///
    /// Returns `nil` when `operation` threw; callers should `guard let ... else { return }`
    /// without further action, since state has already been transitioned when the
    /// generation is still current.
    func runStorage<T>(generation: Int, _ operation: () throws -> T) -> T? {
        do {
            return try operation()
        } catch {
            guard isCurrent(generation) else { return nil }
            sessionState = .storageCorrupted(storageFailure(from: error))
            return nil
        }
    }

    func runStorageVoid(generation: Int, _ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            guard isCurrent(generation) else { return false }
            sessionState = .storageCorrupted(storageFailure(from: error))
            return false
        }
    }

    private func storageFailure(from error: any Error) -> SessionStorageFailure {
        if let profileStoreError = error as? ServerProfileStoreError {
            return .profileStore(profileStoreError)
        }
        return .unexpected
    }

    /// Maps a thrown ``TokenStore`` error to a typed, non-secret ``TokenStoreFailure``,
    /// preserving the exact ``KeychainError`` from the production conformance.
    func tokenStoreFailure(from error: any Error) -> TokenStoreFailure {
        if let keychainError = error as? KeychainError {
            return .keychain(keychainError)
        }
        return .other
    }

    /// Serializes a durable ``TokenStore`` read, save, or delete for `profileID` behind
    /// any earlier one for the same profile that is still in flight.
    ///
    /// A generation check performed only after an awaited call returns is not enough to
    /// keep the token store itself consistent: an in-flight save or delete may (if the
    /// injected ``TokenStore`` does not itself observe cancellation) still complete
    /// after the operation that started it has been superseded, for example by a
    /// profile switch away from and back to the same profile. Routing every access for
    /// a profile through this single per-profile queue guarantees two things: durable
    /// mutations for a profile always apply in the order they were requested (so the
    /// store converges on whichever was requested last, never an earlier one
    /// overwriting a later one), and any later read for that profile always observes
    /// the effect of an earlier, still in-flight mutation rather than a stale value —
    /// so a superseded operation's eventual completion can never leave the token store
    /// and the observable session state inconsistent with each other. Reads and writes
    /// for different profiles remain fully independent.
    @discardableResult
    func serializedTokenAccess<Value: Sendable>(
        for profileID: UUID,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let previous = tokenAccessQueues[profileID]?.task
        let scheduled = Task<Value, any Error> {
            await previous?.value
            return try await operation()
        }
        let tailID = UUID()
        let tail = Task { _ = try? await scheduled.value }
        tokenAccessQueues[profileID] = TokenAccessTail(id: tailID, task: tail)
        defer {
            if tokenAccessQueues[profileID]?.id == tailID {
                tokenAccessQueues[profileID] = nil
            }
        }
        return try await scheduled.value
    }
}
