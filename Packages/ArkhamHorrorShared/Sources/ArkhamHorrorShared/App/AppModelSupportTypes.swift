import Foundation

/// Small, standalone value types shared by `AppModel` and its `AppModel+*.swift`
/// extension files -- split out purely to keep `AppModel.swift` itself under this
/// project's per-file line-length convention; each type's own documentation notes
/// which `AppModel` member(s) it backs.
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

/// A cancellation-cleanup deletion that ultimately failed after being durably
/// reserved (see ``AppModel/enqueueCancellationCleanup(for:globalEpoch:)``), tagged
/// with the exact cleanup-attempt identity that produced it. See
/// ``AppModel/pendingCleanupFailures``.
struct PendingCleanupFailure: Equatable, Sendable {
    let attemptID: UUID
    let failure: TokenStoreFailure
}

/// A ``SessionOperationFailure`` tagged with the exact sign-in/registration attempt
/// (see ``AppModel/currentAuthAttemptID``) that produced it. See
/// ``AppModel/authFailure``.
struct AttemptScopedAuthFailure: Equatable, Sendable {
    let attemptID: UUID
    let failure: SessionOperationFailure
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

/// The operation generation captured at the start of a profile edit that may need to
/// delete an existing token as the precondition for an endpoint change, threaded
/// through as a single value for the same reason as ``CredentialOperationContext``.
/// `cleanupTask` is `nil` exactly when the edit does not change the profile's
/// endpoint (so no token deletion is needed); when present, it is the durable
/// cancellation-cleanup reservation's task returned by
/// ``AppModel/enqueueCancellationCleanup(for:globalEpoch:)`` — the same durable
/// mark-then-admit primitive an explicit auth cancellation uses — so an
/// endpoint-changing edit gets the identical crash-durable tombstone and
/// synchronous-admission guarantees rather than a separate, ad hoc delete path.
struct ProfileUpdateEpochContext: Sendable {
    let cleanupTask: Task<TokenStoreFailure?, Never>?
    let operationGeneration: Int
}
