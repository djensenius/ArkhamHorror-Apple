import Foundation

/// Compatibility probing and token restoration for the selected profile.
extension AppModel {
    func probeAndRestore(profile: ServerProfile, generation: Int) async {
        let outcome: CompatibilityOutcome
        do {
            outcome = try await capabilityProbe.probe(profile)
        } catch {
            guard let reason = probeUnavailableReason(from: error) else { return }
            guard isCurrent(generation) else { return }
            sessionState = .unavailable(profile: profile, reason: reason)
            return
        }

        let compatibility: ServerCompatibility
        switch outcome {
        case let .compatible(capabilities):
            compatibility = .modern(capabilities: capabilities)
        case .legacyFallback:
            compatibility = .legacy
        case let .incompatible(reason):
            guard isCurrent(generation) else { return }
            sessionState = .incompatible(profile: profile, reason: reason)
            return
        }

        guard isCurrent(generation) else { return }
        await restoreToken(profile: profile, compatibility: compatibility, generation: generation)
    }

    /// Maps a thrown probe error to an unavailable reason, or `nil` for cancellation
    /// (which must not become an error).
    private func probeUnavailableReason(from error: any Error) -> SessionUnavailableReason? {
        if error is CancellationError {
            return nil
        }
        if let probeError = error as? CapabilityProbeError {
            return .probeFailed(probeError)
        }
        return .probeFailed(.transportFailure("Unexpected capability probe failure."))
    }

    func restoreToken(
        profile: ServerProfile,
        compatibility: ServerCompatibility,
        generation: Int
    ) async {
        // Captured once, here, before any awaited step in this token-restore chain —
        // not re-read right before the read or the possible unauthorized-delete below
        // — so that an endpoint edit/removal which invalidates this profile's epoch at
        // any point during this chain (including while queued behind that edit's own
        // delete) is guaranteed to leave this capture stale. See
        // ``AppModel/serializedTokenAccess(for:epoch:_:)``.
        let credentialEpoch = currentCredentialEpoch(for: profile.id)
        let token: String?
        do {
            // Serialized (see ``AppModel/serializedTokenAccess(for:epoch:_:)``) so this
            // read always observes the effect of an earlier, still in-flight save or
            // delete for the same profile rather than a stale value.
            token = try await serializedTokenAccess(
                for: profile.id, epoch: credentialEpoch
            ) { [tokenStore] in
                try await tokenStore.token(for: profile.id)
            }
        } catch {
            guard !(error is CancellationError || error is StaleCredentialEpochError) else {
                return
            }
            guard isCurrent(generation) else { return }
            let reason = TokenValidationFailure.tokenStore(tokenStoreFailure(from: error))
            sessionState = .unavailable(profile: profile, reason: .tokenValidationFailed(reason))
            return
        }

        guard let token else {
            guard isCurrent(generation) else { return }
            sessionState = .signedOut(profile: profile, compatibility: compatibility)
            return
        }

        await validateRestoredToken(
            token,
            profile: profile,
            compatibility: compatibility,
            generation: generation,
            credentialEpoch: credentialEpoch
        )
    }

    private func validateRestoredToken(
        _ token: String,
        profile: ServerProfile,
        compatibility: ServerCompatibility,
        generation: Int,
        credentialEpoch: Int
    ) async {
        do {
            let user = try await authenticationSession.currentUser(on: profile, token: token)
            guard isCurrent(generation) else { return }
            sessionState = .signedIn(profile: profile, compatibility: compatibility, user: user)
        } catch is CancellationError {
            return
        } catch AuthenticationError.unauthorized {
            // Checked here, immediately before the deletion is even requested, so a
            // whoami that resolves `.unauthorized` after this operation has been
            // superseded (e.g. by a profile switch away and back to the same profile,
            // where a newer operation has since established a current token) cannot
            // delete that newer token.
            guard isCurrent(generation) else { return }
            await deleteUnauthorizedToken(
                profile: profile,
                compatibility: compatibility,
                generation: generation,
                credentialEpoch: credentialEpoch
            )
        } catch {
            // Any other failure (transient network/TLS/status/decoding) retains the
            // token and is surfaced as a distinct, retryable unavailable reason.
            guard isCurrent(generation) else { return }
            let authError = (error as? AuthenticationError)
                ?? .transportFailure("Unexpected authentication failure.")
            let reason = TokenValidationFailure.authentication(authError)
            sessionState = .unavailable(profile: profile, reason: .tokenValidationFailed(reason))
        }
    }

    /// The server explicitly rejected the stored token: delete it before reporting
    /// signed-out. If deletion itself fails, the (now-known-invalid) token is left in
    /// place and the failure is surfaced distinctly rather than reporting signed-out.
    func deleteUnauthorizedToken(
        profile: ServerProfile,
        compatibility: ServerCompatibility,
        generation: Int,
        credentialEpoch: Int
    ) async {
        do {
            // Serialized (see ``AppModel/serializedTokenAccess(for:epoch:_:)``) so this
            // delete is ordered against any other in-flight read/save/delete for the
            // same profile rather than racing them.
            try await serializedTokenAccess(
                for: profile.id, epoch: credentialEpoch
            ) { [tokenStore] in
                try await tokenStore.deleteToken(for: profile.id)
            }
        } catch {
            guard !(error is CancellationError || error is StaleCredentialEpochError) else {
                return
            }
            guard isCurrent(generation) else { return }
            let reason = TokenValidationFailure.tokenStore(tokenStoreFailure(from: error))
            sessionState = .unavailable(profile: profile, reason: .tokenValidationFailed(reason))
            return
        }
        guard isCurrent(generation) else { return }
        sessionState = .signedOut(profile: profile, compatibility: compatibility)
    }
}
