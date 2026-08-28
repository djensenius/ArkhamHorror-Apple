import Foundation

/// Profile selection and retry: restarting the compatibility/token-restoration flow.
extension AppModel {
    /// Selects `profile`, persists the selection, and restarts the compatibility and
    /// token-restoration flow for it.
    ///
    /// `profile` must already be a member of ``profiles``; profile creation and removal
    /// are out of scope for this coordinator. Any superseded flow or operation task is
    /// cancelled and its completion is guarded by the incremented generation counter.
    func selectProfile(_ profile: ServerProfile) {
        guard profiles.contains(where: { $0.id == profile.id }) else { return }
        // If a sign-in/registration is in flight for the profile being switched away
        // from, it must be interrupted exactly as an explicit ``cancelAuthOperation()``
        // would be: a save that has already passed its epoch recheck (or already
        // durably applied) must still be cleaned up, or switching back to that profile
        // later could silently observe — and sign in with — a token this switch was
        // supposed to abandon. This must happen here, before `flowTask`/`operationTask`
        // are cancelled and before `generation`/`selectedProfile` change, while
        // `sessionState` still names the profile whose operation is being interrupted.
        // If that cleanup cannot be durably reserved, the switch itself must not
        // proceed — completing it anyway would abandon an unprotected in-flight save.
        switch interruptActiveAuthOperationIfNeeded() {
        case .none, .interrupted:
            break
        case let .blocked(failure):
            operationFailure = .tokenStore(failure)
            return
        }
        flowTask?.cancel()
        operationTask?.cancel()
        generation += 1
        let currentGeneration = generation
        selectedProfile = profile
        operation = .idle
        operationFailure = nil
        guard runStorageVoid(generation: currentGeneration, {
            try profileStore.saveSelectedProfileID(profile.id)
        }) else { return }
        restartFlow(for: profile, generation: currentGeneration)
    }

    /// Retries the compatibility probe and token restoration for the currently
    /// unavailable or incompatible profile. A no-op from any other state.
    func retry() {
        let profile: ServerProfile
        switch sessionState {
        case let .unavailable(unavailableProfile, _):
            profile = unavailableProfile
        case let .incompatible(incompatibleProfile, _):
            profile = incompatibleProfile
        default:
            return
        }
        // Defense in depth, matching ``selectProfile(_:)``: `operation` cannot
        // actually be `.signingIn`/`.registering` while `sessionState` is
        // `.unavailable`/`.incompatible` in the current design (every transition away
        // from `.signedOut` already resets `operation` to `.idle` first), but this
        // guards against that invariant ever being violated by a future change rather
        // than relying on it silently.
        switch interruptActiveAuthOperationIfNeeded() {
        case .none, .interrupted:
            break
        case let .blocked(failure):
            operationFailure = .tokenStore(failure)
            return
        }
        flowTask?.cancel()
        operationTask?.cancel()
        generation += 1
        let currentGeneration = generation
        operation = .idle
        operationFailure = nil
        restartFlow(for: profile, generation: currentGeneration)
    }

    /// Transitions to ``SessionState/checkingCompatibility(profile:)`` and starts a
    /// fresh compatibility/token-restoration flow task for `profile` at `generation`.
    ///
    /// Not `private` so ``AppModel``'s profile-management extension can reuse it after
    /// an in-place edit or removal of the currently selected profile forces the same
    /// restart, without duplicating the probe/restore wiring.
    func restartFlow(for profile: ServerProfile, generation: Int) {
        sessionState = .checkingCompatibility(profile: profile)
        flowTask = Task { [weak self] in
            await self?.probeAndRestore(profile: profile, generation: generation)
        }
    }
}
