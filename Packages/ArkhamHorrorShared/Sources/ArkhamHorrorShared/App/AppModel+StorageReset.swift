import Foundation

/// Explicit, user-confirmed recovery from corrupted profile/selection storage.
///
/// Kept separate from ``AppModel/addCustomProfile(displayName:rawURL:)`` /
/// ``AppModel/updateCustomProfile(_:)`` / ``AppModel/removeCustomProfile(_:)`` (in
/// `AppModel+ProfileManagement.swift`) purely to keep each file under the project's
/// file-length convention; this remains part of the same profile-management concern
/// and shares its `profileManagementOperation`/`profileManagementGeneration` state.
extension AppModel {
    /// Explicitly, and only from ``SessionState/storageCorrupted(_:)``, securely
    /// deletes every stored token before discarding the unreadable profile/selection
    /// storage, reseeds only the canonical hosted profile, persists that reset, and
    /// restarts the launch flow.
    ///
    /// Never called implicitly: presentation code must obtain explicit user
    /// confirmation (e.g. a destructive confirmation alert) before invoking this, since
    /// corrupted storage is otherwise surfaced rather than silently erased.
    ///
    /// By the time storage is genuinely corrupted (as opposed to selection-only
    /// corruption, which ``AppModel/loadProfilesAndSelect(generation:)`` already
    /// repairs without ever reaching this state), the previously known profile IDs can
    /// no longer be trusted enough to delete their tokens individually, so this uses
    /// ``TokenStore/deleteAllTokens()`` — scoped only to this store's own
    /// service/namespace — instead. Credential cleanup must succeed before the old
    /// metadata is irreversibly replaced: `errSecItemNotFound` (nothing to delete) is
    /// success, but any other failure preserves the old stored state untouched and
    /// surfaces a typed, actionable failure rather than orphaning tokens whose owning
    /// profile metadata has just been erased.
    func confirmStorageReset() {
        guard case .storageCorrupted = sessionState else { return }
        guard profileManagementOperation == .idle else { return }
        flowTask?.cancel()
        operationTask?.cancel()
        profileManagementTask?.cancel()
        generation += 1
        let currentGeneration = generation
        profileManagementFailure = nil
        profileManagementOperation = .resettingStorage
        profileManagementGeneration += 1
        let operationGeneration = profileManagementGeneration

        // The service-wide credential epoch is bumped, and every per-profile queue
        // tail currently in flight is snapshotted, synchronously here — *before* the
        // barrier below is installed — so that:
        //   - every token operation already enqueued anywhere, captured under any
        //     earlier global epoch, is guaranteed to observe a mismatch at its
        //     recheck (which can only run after the snapshotted tails it is chained
        //     behind complete, and after the barrier this method installs resolves);
        //   - every new token operation that starts after this method returns
        //     observes the freshly installed barrier (`serviceResetBarrier`) and
        //     waits behind it, rather than racing `deleteAllTokens()` below.
        // The barrier task itself awaits exactly the snapshotted tails (never a new
        // operation's own tail, which instead awaits the barrier) before running the
        // wipe, so no self-wait/deadlock is possible.
        globalCredentialEpoch += 1
        let pendingTails = tokenAccessQueues.values.map(\.task)

        let barrierID = UUID()
        let barrierTask = Task<Void, Never> { [weak self] in
            for tail in pendingTails {
                await tail.value
            }
            guard let self else { return }
            await performStorageReset(
                generation: currentGeneration, operationGeneration: operationGeneration
            )
            if serviceResetBarrier?.id == barrierID {
                serviceResetBarrier = nil
            }
        }
        serviceResetBarrier = ServiceResetBarrier(id: barrierID, task: barrierTask)
        profileManagementTask = barrierTask
    }

    private func performStorageReset(generation: Int, operationGeneration: Int) async {
        defer {
            if isCurrentProfileOperation(operationGeneration) {
                profileManagementOperation = .idle
            }
        }

        guard await deleteAllTokensForReset(operationGeneration: operationGeneration) else {
            return
        }
        guard isCurrentProfileOperation(operationGeneration) else { return }
        guard isCurrent(generation) else { return }

        // Every durable cleanup tombstone may only be cleared *after*
        // `deleteAllTokensForReset` above has already succeeded, and clearing itself
        // must succeed *before* the old metadata below is irreversibly replaced —
        // exactly like the delete above, this is a required precondition, not a
        // best-effort hygiene step. A clear failure preserves the old (corrupted)
        // stored state and every tombstone untouched, surfaces a typed, actionable
        // failure, and is retryable: a subsequent reset attempt's own delete finds
        // nothing left to delete (already idempotent) and this clear is itself
        // idempotent.
        guard clearAllTombstonesForReset(operationGeneration: operationGeneration) else {
            return
        }
        guard isCurrentProfileOperation(operationGeneration) else { return }
        guard isCurrent(generation) else { return }

        let resetProfiles = [ServerProfile.hosted]
        guard runStorageVoid(generation: generation, {
            try profileStore.saveProfiles(resetProfiles)
        }) else { return }
        guard runStorageVoid(generation: generation, {
            try profileStore.saveSelectedProfileID(ServerProfile.hosted.id)
        }) else { return }
        guard isCurrent(generation) else { return }

        profiles = resetProfiles
        selectedProfile = .hosted
        operation = .idle
        operationFailure = nil
        restartFlow(for: .hosted, generation: generation)
    }

    /// Deletes every stored token as the first, required step of a storage reset.
    /// Failure (other than cancellation) preserves the old (corrupted) stored state
    /// untouched and surfaces a typed, actionable failure rather than replacing
    /// metadata while tokens may still exist under it.
    func deleteAllTokensForReset(operationGeneration: Int) async -> Bool {
        do {
            try await tokenStore.deleteAllTokens()
            return true
        } catch {
            guard isCurrentProfileOperation(operationGeneration) else { return false }
            guard !(error is CancellationError) else { return false }
            profileManagementFailure = .tokenStore(tokenStoreFailure(from: error))
            return false
        }
    }

    /// Clears every durable cleanup tombstone as the second, required step of a
    /// storage reset (only reached once `deleteAllTokensForReset` has succeeded).
    /// Failure preserves the old (corrupted) stored state and every tombstone
    /// untouched and surfaces a typed, actionable, retryable failure. Success also
    /// clears every profile's ``pendingCleanupFailures`` entry: with every tombstone
    /// gone, no cleanup obligation can still be genuinely outstanding for any
    /// profile, so none should keep being surfaced as one.
    func clearAllTombstonesForReset(operationGeneration: Int) -> Bool {
        do {
            try cleanupPendingStore.clearAll()
            pendingCleanupFailures.removeAll()
            return true
        } catch {
            guard isCurrentProfileOperation(operationGeneration) else { return false }
            profileManagementFailure = .tokenStore(tokenStoreFailure(from: error))
            return false
        }
    }
}
