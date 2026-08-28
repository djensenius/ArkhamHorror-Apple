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
    /// ``serializedTokenAccess(for:epoch:_:)``.
    @ObservationIgnored var tokenAccessQueues: [UUID: TokenAccessTail] = [:]

    /// A per-profile counter guarding stale durable token-store mutations at the
    /// instant they would actually touch the Keychain — the last line of defense
    /// against the race a generation check alone cannot close. See
    /// ``invalidateCredentialEpoch(for:)`` and ``serializedTokenAccess(for:epoch:_:)``.
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
    /// operation before running ``TokenStore/deleteAllTokens()``. Every
    /// ``serializedTokenAccess(for:epoch:globalEpoch:_:)`` call awaits this barrier's
    /// `task` (if still present at the moment its own turn arrives) before rechecking
    /// epochs, so a token operation that begins while a reset is in flight can never
    /// run ahead of, or race, the reset's own drain-then-wipe sequence. Cleared (via an
    /// identity check against `id`) once the reset itself has fully resolved, whether it
    /// succeeded or failed.
    @ObservationIgnored var serviceResetBarrier: ServiceResetBarrier?

    /// A cancellation-cleanup delete's most recently observed outcome for a profile,
    /// keyed by profile ID, consulted (and consumed) by
    /// ``beginAuthOperation(_:issueToken:)`` and
    /// ``restoreToken(profile:compatibility:generation:)`` so neither can silently
    /// trust a token that a cancelled operation's cleanup failed to remove. See
    /// ``enqueueCancellationCleanup(for:globalEpoch:)``.
    @ObservationIgnored var cancellationCleanupFailures: [UUID: TokenStoreFailure] = [:]

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

    /// Serializes a durable ``TokenStore`` read, save, or delete for `profileID` behind
    /// any earlier one for the same profile that is still in flight, only actually
    /// running `operation` if `epoch` still matches ``credentialEpochs`` for
    /// `profileID`, and `globalEpoch` still matches ``globalCredentialEpoch``, at the
    /// instant it is about to run — also awaiting an active ``serviceResetBarrier``, if
    /// any is present at that instant, first.
    ///
    /// A generation check performed only before enqueueing, or only after an awaited
    /// call returns, is not enough to keep the token store itself consistent with the
    /// profile's *current* endpoint: an in-flight save may already be queued behind an
    /// endpoint edit's or removal's delete by the time that edit/removal invalidates
    /// the profile's credential epoch, so a generation check made when the save was
    /// *enqueued* can never observe that later invalidation. `epoch` must therefore be
    /// captured once, by the caller, at the same point its ``AppModel/generation`` is
    /// captured (operation start), and threaded through unchanged; this function then
    /// rechecks it against the live epoch immediately before `operation` runs — the
    /// last possible moment before the Keychain is actually touched — so an
    /// already-enqueued stale save can never durably resurrect a token for a
    /// since-changed or since-removed endpoint. The same reasoning applies to
    /// `globalEpoch` against a service-wide storage reset (``confirmStorageReset()``):
    /// capturing it once, at the same moment as `epoch`, and rechecking it here
    /// guarantees a reset that begins after this operation started — even one whose
    /// own drain-then-wipe sequence this operation ends up queued behind — is never
    /// raced by a save this operation was already committed to making. On either
    /// mismatch, `operation` is skipped and ``StaleCredentialEpochError`` is thrown;
    /// every call site treats this exactly like ``CancellationError`` (never surfaced
    /// as a user-facing failure).
    ///
    /// Beyond credential-epoch safety, this also preserves the existing ordering
    /// guarantee: durable mutations for a profile always apply in the order they were
    /// requested, and any later read for that profile always observes the effect of an
    /// earlier, still in-flight mutation rather than a stale value. Reads and writes
    /// for different profiles remain fully independent.
    @discardableResult
    func serializedTokenAccess<Value: Sendable>(
        for profileID: UUID,
        epoch: Int,
        globalEpoch: Int,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let previous = tokenAccessQueues[profileID]?.task
        let scheduled = Task<Value, any Error> {
            await previous?.value
            if let barrier = self.serviceResetBarrier {
                await barrier.task.value
            }
            guard self.credentialEpochs[profileID, default: 0] == epoch,
                  self.globalCredentialEpoch == globalEpoch
            else {
                throw StaleCredentialEpochError()
            }
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

    /// The current credential epoch for `profileID` (`0` if never invalidated), for a
    /// caller to capture once at the start of an operation alongside ``generation``.
    func currentCredentialEpoch(for profileID: UUID) -> Int {
        credentialEpochs[profileID, default: 0]
    }

    /// The current service-wide credential epoch, for a caller to capture once at the
    /// start of an operation alongside ``currentCredentialEpoch(for:)`` and
    /// ``generation``.
    func currentGlobalCredentialEpoch() -> Int {
        globalCredentialEpoch
    }

    /// Advances the credential epoch for `profileID` and returns the new value.
    ///
    /// Must be called synchronously, before enqueueing the delete that follows from
    /// the same invalidating event (an endpoint edit, a profile removal, a storage
    /// reset, or an explicit auth cancellation), so that no already-in-flight or
    /// not-yet-enqueued operation captured before this call can observe the new value
    /// as if it were its own — every other in-flight operation for this profile must
    /// have captured its epoch strictly earlier, and will therefore fail its recheck.
    @discardableResult
    func invalidateCredentialEpoch(for profileID: UUID) -> Int {
        let next = credentialEpochs[profileID, default: 0] + 1
        credentialEpochs[profileID] = next
        return next
    }

    /// Synchronously, unconditionally enqueues a token deletion for `profileID` behind
    /// whatever token-store operation is currently at the tail of its serialized
    /// queue — registering the new tail *before this function returns*, not merely
    /// inside a separately-scheduled ``Task``, so any operation that begins after
    /// ``cancelAuthOperation()`` returns (even one whose own async steps have not yet
    /// reached ``serializedTokenAccess(for:epoch:globalEpoch:_:)``) is guaranteed to be
    /// queued strictly behind this cleanup rather than racing ahead of, and being
    /// wiped by, it.
    ///
    /// Unlike ``serializedTokenAccess(for:epoch:globalEpoch:_:)``, this delete is not
    /// itself gated on a profile credential epoch: its entire purpose is to remove
    /// whatever a just-cancelled operation's save may already have written under the
    /// very epoch this call's own caller just bumped, so gating it on that epoch would
    /// make it a guaranteed no-op. It still respects an active service-wide reset
    /// barrier and `globalEpoch`, so it can never race ``TokenStore/deleteAllTokens()``.
    ///
    /// On failure (and only then), records `profileID`'s failure in
    /// ``cancellationCleanupFailures`` — consulted (and consumed) by
    /// ``beginAuthOperation(_:issueToken:)`` and
    /// ``restoreToken(profile:compatibility:generation:)`` so a stale, undeleted token
    /// is never silently trusted by a later operation for the same profile. On
    /// success, clears any previously recorded failure for `profileID`, since the
    /// store is now known to be reachable and clean again.
    func enqueueCancellationCleanup(for profileID: UUID, globalEpoch: Int) {
        let previous = tokenAccessQueues[profileID]?.task
        let scheduled = Task<Void, any Error> {
            await previous?.value
            if let barrier = self.serviceResetBarrier {
                await barrier.task.value
            }
            guard self.globalCredentialEpoch == globalEpoch else {
                throw StaleCredentialEpochError()
            }
            try await self.tokenStore.deleteToken(for: profileID)
        }
        let tailID = UUID()
        let tail = Task { [weak self] in
            do {
                try await scheduled.value
                self?.cancellationCleanupFailures[profileID] = nil
            } catch is CancellationError {
            } catch is StaleCredentialEpochError {
            } catch {
                guard let self else { return }
                cancellationCleanupFailures[profileID] = tokenStoreFailure(from: error)
            }
            if self?.tokenAccessQueues[profileID]?.id == tailID {
                self?.tokenAccessQueues[profileID] = nil
            }
        }
        tokenAccessQueues[profileID] = TokenAccessTail(id: tailID, task: tail)
    }
}

/// Thrown by ``AppModel/serializedTokenAccess(for:epoch:_:)`` when a queued token
/// operation's captured epoch no longer matches the profile's current credential
/// epoch. Carries no data and is always treated exactly like ``CancellationError``: it
/// must never be surfaced as a user-facing failure.
struct StaleCredentialEpochError: Error {}
