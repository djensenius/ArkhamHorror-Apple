import Foundation

/// Explicit, user-confirmed recovery from a corrupted credential-cleanup tombstone
/// registry (``SessionState/credentialCleanupRegistryCorrupted(_:)``), distinct from
/// ``AppModel/confirmStorageReset()``: this recovery only ever resets credential
/// material, never any saved server-profile metadata.
extension AppModel {
    /// Explicitly, and only from
    /// ``SessionState/credentialCleanupRegistryCorrupted(_:)``, securely deletes
    /// every stored token and clears every durable cleanup marker, then restarts the
    /// launch flow for the currently selected profile.
    ///
    /// Never called implicitly: presentation code must obtain explicit user
    /// confirmation before invoking this, matching ``confirmStorageReset()``'s
    /// contract. Unlike that reset, this never touches `profiles`/`selectedProfile`:
    /// only the shared credential-cleanup registry and every stored token are
    /// corrupt/reset here, never profile metadata, so a user's saved custom servers
    /// survive this recovery. Reuses the exact same barrier/ordering primitives
    /// (``deleteAllTokensForReset(operationGeneration:)`` then
    /// ``clearAllTombstonesForReset(operationGeneration:)``, behind a
    /// ``serviceResetBarrier`` that every in-flight token operation is guaranteed to
    /// observe) since both recoveries share the identical fail-closed, ordered
    /// credential-wipe requirement — only what is (and is not) reset afterward
    /// differs.
    func confirmCredentialCleanupRegistryReset() {
        guard case .credentialCleanupRegistryCorrupted = sessionState else { return }
        guard profileManagementOperation == .idle else { return }
        flowTask?.cancel()
        operationTask?.cancel()
        profileManagementTask?.cancel()
        generation += 1
        let currentGeneration = generation
        profileManagementFailure = nil
        profileManagementOperation = .resettingCredentialCleanupRegistry
        profileManagementGeneration += 1
        let operationGeneration = profileManagementGeneration

        // See ``confirmStorageReset()`` for why the epoch bump/tail snapshot happen
        // synchronously here, before the barrier is installed: every already
        // in-flight token operation is guaranteed to observe a mismatch at its
        // recheck, and every new one waits behind the barrier rather than racing
        // `deleteAllTokens()` below.
        globalCredentialEpoch += 1
        let pendingTails = tokenAccessQueues.values.map(\.task)

        let barrierID = UUID()
        let barrierTask = Task<Void, Never> { [weak self] in
            for tail in pendingTails {
                await tail.value
            }
            guard let self else { return }
            await performCredentialCleanupRegistryReset(
                generation: currentGeneration, operationGeneration: operationGeneration
            )
            if serviceResetBarrier?.id == barrierID {
                serviceResetBarrier = nil
            }
        }
        serviceResetBarrier = ServiceResetBarrier(id: barrierID, task: barrierTask)
        profileManagementTask = barrierTask
    }

    private func performCredentialCleanupRegistryReset(
        generation: Int, operationGeneration: Int
    ) async {
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

        // As in `performStorageReset`, tombstones may only be cleared *after* the
        // delete above has already succeeded.
        guard clearAllTombstonesForReset(operationGeneration: operationGeneration) else {
            return
        }
        guard isCurrentProfileOperation(operationGeneration) else { return }
        guard isCurrent(generation) else { return }

        operation = .idle
        operationFailure = nil
        restartFlow(for: selectedProfile, generation: generation)
    }
}
