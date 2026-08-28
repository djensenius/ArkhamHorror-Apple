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
        return .probeFailed(.transportFailure(String(describing: error)))
    }

    func restoreToken(
        profile: ServerProfile,
        compatibility: ServerCompatibility,
        generation: Int
    ) async {
        let token: String?
        do {
            token = try await tokenStore.token(for: profile.id)
        } catch {
            guard !(error is CancellationError) else { return }
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
            generation: generation
        )
    }

    private func validateRestoredToken(
        _ token: String,
        profile: ServerProfile,
        compatibility: ServerCompatibility,
        generation: Int
    ) async {
        do {
            let user = try await authenticationSession.currentUser(on: profile, token: token)
            guard isCurrent(generation) else { return }
            sessionState = .signedIn(profile: profile, compatibility: compatibility, user: user)
        } catch is CancellationError {
            return
        } catch AuthenticationError.unauthorized {
            await deleteUnauthorizedToken(
                profile: profile,
                compatibility: compatibility,
                generation: generation
            )
        } catch {
            // Any other failure (transient network/TLS/status/decoding) retains the
            // token and is surfaced as a distinct, retryable unavailable reason.
            guard isCurrent(generation) else { return }
            let authError = (error as? AuthenticationError)
                ?? .transportFailure(String(describing: error))
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
        generation: Int
    ) async {
        do {
            try await tokenStore.deleteToken(for: profile.id)
        } catch {
            guard !(error is CancellationError) else { return }
            guard isCurrent(generation) else { return }
            let reason = TokenValidationFailure.tokenStore(tokenStoreFailure(from: error))
            sessionState = .unavailable(profile: profile, reason: .tokenValidationFailed(reason))
            return
        }
        guard isCurrent(generation) else { return }
        sessionState = .signedOut(profile: profile, compatibility: compatibility)
    }
}
