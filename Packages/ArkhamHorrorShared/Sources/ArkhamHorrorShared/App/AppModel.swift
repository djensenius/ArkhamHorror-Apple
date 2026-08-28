import Foundation
import Observation

struct TokenAccessTail {
    let id: UUID
    let task: Task<Void, Never>
}

/// A service-wide credential-reset barrier: while active, every per-profile token
/// operation awaits `task` before proceeding. See ``AppModel/serviceResetBarrier``.
struct ServiceResetBarrier {
    let id: UUID
    let task: Task<Void, Never>
}

/// A cancellation-cleanup deletion's tracked, awaitable outcome for a profile, keyed
/// by profile ID, so a later caller (``AppModel/resolvePendingCleanup(for:)``) can
/// await the *same* in-flight cleanup rather than racing a second, redundant delete
/// for the same profile. Pruned (via an identity check against `id`) once its task
/// completes, exactly like ``TokenAccessTail``.
struct CleanupPendingTask {
    let id: UUID
    let task: Task<TokenStoreFailure?, Never>
}

/// The generation and credential/global epoch snapshot captured at the start of an
/// operation that may reach a durable token mutation, threaded through as a single
/// value so the functions that recheck it immediately before touching the token
/// store do not need a separate parameter for each field. See
/// ``AppModel/serializedTokenAccess(for:epoch:globalEpoch:_:)`` and
/// ``AppModel/isCurrent(_:)``.
struct CredentialOperationContext: Sendable {
    let generation: Int
    let credentialEpoch: Int
    let globalEpoch: Int
}

/// The global/profile epoch snapshot and operation generation captured at the start
/// of a profile edit that may need to delete an existing token as the precondition
/// for an endpoint change, threaded through as a single value for the same reason as
/// ``CredentialOperationContext``. `credentialEpoch` is `nil` exactly when the edit
/// does not change the profile's endpoint (so no token deletion is needed).
struct ProfileUpdateEpochContext: Sendable {
    let credentialEpoch: Int?
    let globalEpoch: Int
    let operationGeneration: Int
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
    /// Durable, non-secret record of which profiles have a cleanup deletion pending.
    /// See ``resolvePendingCleanup(for:)`` and
    /// ``enqueueCancellationCleanup(for:globalEpoch:)``.
    @ObservationIgnored let cleanupPendingStore: any TokenCleanupPendingStore

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
    /// ``serializedTokenAccess(for:epoch:globalEpoch:_:)``.
    @ObservationIgnored var tokenAccessQueues: [UUID: TokenAccessTail] = [:]

    /// A per-profile counter guarding stale durable token-store mutations at the
    /// instant they would actually touch the Keychain — the last line of defense
    /// against the race a generation check alone cannot close. See
    /// ``invalidateCredentialEpoch(for:)`` and
    /// ``serializedTokenAccess(for:epoch:globalEpoch:_:)``.
    @ObservationIgnored var credentialEpochs: [UUID: Int] = [:]

    /// A service-wide counter, parallel to ``credentialEpochs`` but scoped to the
    /// entire token store rather than one profile, guarding every durable token-store
    /// mutation against a concurrent full storage reset (``confirmStorageReset()``).
    /// Bumped synchronously, before ``deleteAllTokens()`` is even enqueued, so every
    /// per-profile operation captured under an earlier value — in flight, merely
    /// queued, or not yet started — is guaranteed to observe a mismatch once its own
    /// recheck actually runs. See ``serviceResetBarrier`` and
    /// ``serializedTokenAccess(for:epoch:globalEpoch:_:)``.
    @ObservationIgnored var globalCredentialEpoch = 0

    /// While non-`nil`, a service-wide reset is draining every pre-existing per-profile
    /// operation before running ``TokenStore/deleteAllTokens()``.
    ///
    /// Every ``serializedTokenAccess(for:epoch:globalEpoch:_:)`` and
    /// ``enqueueCancellationCleanup(for:globalEpoch:)`` call captures this value
    /// synchronously, at *enqueue* time (before constructing its async task body),
    /// never re-reading it dynamically once that body actually runs. This admission
    /// decision is what makes an operation either strictly part of a reset's
    /// `pendingTails` snapshot (enqueued before the barrier was installed, so it never
    /// awaits it) or strictly behind the barrier (enqueued after, so it always awaits
    /// it, captured as non-`nil`) — never both, never neither. A dynamic re-read
    /// inside the task body would instead let an operation that was already part of
    /// the barrier's own `pendingTails` snapshot observe the barrier as installed and
    /// await it too, which is exactly the barrier's own transitive dependency on that
    /// same operation — a self-referential deadlock. Cleared (via an identity check
    /// against `id`) once the reset itself has fully resolved, whether it succeeded or
    /// failed.
    @ObservationIgnored var serviceResetBarrier: ServiceResetBarrier?

    /// In-flight cleanup-deletion tasks, keyed by profile ID, so
    /// ``resolvePendingCleanup(for:)`` can await an already-enqueued cleanup for a
    /// profile rather than racing a redundant second delete for it. See
    /// ``CleanupPendingTask``.
    @ObservationIgnored var cleanupPendingTasks: [UUID: CleanupPendingTask] = [:]

    /// Test-only synchronous admission hook: invoked immediately after a token-access
    /// operation (``serializedTokenAccess(for:epoch:globalEpoch:_:)`` or
    /// ``enqueueCancellationCleanup(for:globalEpoch:)``) registers itself as the new
    /// tail for `profileID` in ``tokenAccessQueues`` — synchronously, before either
    /// function returns. Always `nil` in production. Deterministic tests use this to
    /// await a specific enqueue actually having been admitted into the per-profile
    /// queue, instead of inferring scheduler progress via a fixed number of yields
    /// (which cannot, in general, bound how many asynchronous steps precede a given
    /// call reaching this point).
    @ObservationIgnored var tokenAccessAdmissionHook: (@Sendable (UUID) -> Void)?

    init(
        profileStore: any ServerProfileStore = UserDefaultsServerProfileStore(),
        tokenStore: any TokenStore = KeychainTokenStore(),
        capabilityProbe: any CapabilityProbing = CapabilityProbe(),
        authenticationSession: any AppAuthenticating = AuthenticationSession(),
        cleanupPendingStore: any TokenCleanupPendingStore = UserDefaultsTokenCleanupPendingStore()
    ) {
        self.profileStore = profileStore
        self.tokenStore = tokenStore
        self.capabilityProbe = capabilityProbe
        self.authenticationSession = authenticationSession
        self.cleanupPendingStore = cleanupPendingStore
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

    func storageFailure(from error: any Error) -> SessionStorageFailure {
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
}
