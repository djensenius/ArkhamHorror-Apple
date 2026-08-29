import Foundation

/// Detection and entry into the credential-cleanup-registry-corrupted session state.
///
/// Split out of ``AppModel+CleanupReservation.swift`` purely by file size; every
/// member here operates on exactly the same `@MainActor`-isolated state declared in
/// `AppModel.swift` and builds directly on
/// ``AppModel/resolvePendingCleanup(for:)``/``AppModel/cleanupPendingStore``, both
/// defined there/in the sibling file. Explicit, user-confirmed recovery from this
/// state lives separately in `AppModel+CredentialCleanupRegistryReset.swift`.
extension AppModel {
    /// Whether `sessionState` is currently
    /// ``SessionState/credentialCleanupRegistryCorrupted(_:)`` — checked immediately
    /// after ``resolvePendingCleanup(for:)`` (or ``pendingCleanupRegistryIDs()``
    /// directly) reports a failure, so a caller can tell a systemic
    /// registry-enumeration failure (which has already transitioned `sessionState`
    /// itself, session-wide) apart from an ordinary per-profile cleanup failure that
    /// the caller must still surface through its own, narrower state transition —
    /// and, critically, so that narrower transition is skipped when this is `true`,
    /// rather than clobbering the session-wide corruption state with (for example)
    /// a merely-`.unavailable` presentation that a plain ``AppModel/retry()`` could
    /// never actually repair.
    var isCredentialCleanupRegistryCorrupted: Bool {
        if case .credentialCleanupRegistryCorrupted = sessionState {
            return true
        }
        return false
    }

    /// The current durable cleanup-tombstone registry contents, or `nil` after
    /// transitioning `sessionState` into
    /// ``SessionState/credentialCleanupRegistryCorrupted(_:)`` if the registry
    /// itself could not be safely enumerated.
    ///
    /// A registry-enumeration failure (a malformed/non-canonical marker, or an
    /// unhandled Keychain status) is a systemic failure of the *shared* tombstone
    /// service, not any one profile's own token operation, so it is surfaced
    /// session-wide here rather than as a per-profile, retryable failure that plain
    /// ``AppModel/retry()`` could never actually fix by re-probing whichever one
    /// profile happened to trigger this check first. Idempotent: repeated calls
    /// while already corrupted simply return `nil` again without re-mutating
    /// `sessionState` to an equivalent value.
    func pendingCleanupRegistryIDs() -> Set<UUID>? {
        if isCredentialCleanupRegistryCorrupted {
            return nil
        }
        do {
            return try cleanupPendingStore.pendingProfileIDs()
        } catch {
            enterCredentialCleanupRegistryCorrupted(cleanupRegistryFailure(from: error))
            return nil
        }
    }

    /// The single synchronous entry point for transitioning into
    /// ``SessionState/credentialCleanupRegistryCorrupted(_:)`` — currently reached
    /// only from ``pendingCleanupRegistryIDs()``, the sole call site of
    /// ``TokenCleanupPendingStore/pendingProfileIDs()``, but written as the one
    /// mandatory choke point for *any* future enumeration/noncanonical-marker
    /// registry failure rather than a bespoke inline write.
    ///
    /// Idempotent: returns `false`, mutating nothing, if `sessionState` is already
    /// this exact corrupted state — a second, concurrent registry-enumeration
    /// failure discovered by a different in-flight caller (for example, two
    /// unrelated ``resolvePendingCleanup(for:)`` calls racing on MainActor) must
    /// never re-bump every generation/epoch a second time, which would gratuitously
    /// invalidate a legitimate operation that only began *after* the first entry
    /// already completed.
    ///
    /// Every generation/epoch that guards a terminal `sessionState`/durable-token
    /// mutation anywhere in this type is advanced here, synchronously, *before*
    /// `sessionState` itself is published: ``AppModel/generation`` (shared by
    /// launch, sign-in/registration, and profile-selection completions'
    /// ``AppModel/isCurrent(_:)`` rechecks), ``AppModel/profileManagementGeneration``
    /// (profile add/edit/remove completions' ``AppModel/isCurrentProfileOperation(_:)``
    /// rechecks), and ``AppModel/globalCredentialEpoch`` (every per-profile queued
    /// token-store read/save/delete's own recheck in
    /// ``AppModel/serializedTokenAccess(for:epoch:globalEpoch:_:)``/
    /// ``AppModel/enqueueCancellationCleanup(for:globalEpoch:)``). This is exactly
    /// the same "advance every generation before publishing new state" discipline
    /// ``confirmStorageReset()``/``confirmCredentialCleanupRegistryReset()`` already
    /// use for a *confirmed* reset; entering the corrupted state itself now uses it
    /// too, rather than relying solely on each call site separately re-checking
    /// ``isCredentialCleanupRegistryCorrupted`` — a real, but by itself provably
    /// insufficient, second line of defense against a call site that never re-checks
    /// it after an intervening `await` (see ``AppModel/loadProfilesAndSelect(generation:)``,
    /// which now re-checks ``isCurrent(_:)`` immediately after the call that can
    /// reach here, rather than unconditionally overwriting whatever this just
    /// published).
    ///
    /// Cancels (but does not await) the in-flight launch/auth-operation/profile-management
    /// tasks, if any: their own cancellation-completion code paths already re-check
    /// the generation/operation-generation this just bumped before mutating any
    /// terminal state, so a cancellation callback that later runs cannot itself
    /// overwrite the corrupted state installed here. Deliberately does *not* touch
    /// ``cleanupPendingTasks``/``tokenAccessQueues`` (already-reserved,
    /// already-admitted per-profile cleanup deletions or token reads/saves): those
    /// remain individually gated by their own captured generation/credential-epoch —
    /// bumped above — and forcibly cancelling them here would not itself delete or
    /// clear anything; only the explicit, user-confirmed
    /// ``confirmCredentialCleanupRegistryReset()`` recovery is ever allowed to touch
    /// credentials, and only after explicit confirmation.
    ///
    /// Future start/select/auth/profile-management entry points
    /// (``beginAuthOperation(_:issueToken:)``, ``selectProfile(_:)``, ``retry()``,
    /// ``addCustomProfile(displayName:rawURL:)``,
    /// ``updateCustomProfile(_:displayName:rawURL:)``, ``removeCustomProfile(_:)``)
    /// must reject while ``isCredentialCleanupRegistryCorrupted`` is `true` — most
    /// already do so structurally (each requires a `sessionState` this transition
    /// has just moved away from), and the remainder guard it explicitly.
    @discardableResult
    func enterCredentialCleanupRegistryCorrupted(
        _ failure: TokenCleanupPendingStoreError
    ) -> Bool {
        guard !isCredentialCleanupRegistryCorrupted else { return false }
        generation += 1
        profileManagementGeneration += 1
        globalCredentialEpoch += 1
        flowTask?.cancel()
        flowTask = nil
        operationTask?.cancel()
        operationTask = nil
        profileManagementTask?.cancel()
        profileManagementTask = nil
        operation = .idle
        operationFailure = nil
        authFailure = nil
        currentAuthAttemptID = nil
        profileManagementOperation = .idle
        profileManagementFailure = nil
        currentProfileSubmissionID = nil
        sessionState = .credentialCleanupRegistryCorrupted(failure)
        return true
    }

    /// Maps a thrown ``TokenCleanupPendingStore/pendingProfileIDs()`` error to a
    /// typed, non-secret ``TokenCleanupPendingStoreError``, preserving the exact
    /// case from the production conformance and falling back to `.corruptData` for
    /// any non-conforming injected error type (a defensive-only path: this registry
    /// cannot be trusted either way).
    private func cleanupRegistryFailure(from error: any Error) -> TokenCleanupPendingStoreError {
        error as? TokenCleanupPendingStoreError ?? .corruptData
    }
}
