import Foundation

// Deterministic, in-memory dependency fakes used exclusively by `#Preview` fixtures
// across `Presentation/`.
//
// These never touch the network or Keychain: previews must render every adaptive
// layout and state without live I/O or uncontrolled production tasks. Compiled only
// into debug builds, matching their preview-only purpose.
#if DEBUG
    struct PreviewServerProfileStore: ServerProfileStore {
        var profiles: [ServerProfile] = [.hosted]
        var selectedProfileID: UUID? = ServerProfile.hosted.id

        func loadProfiles() throws -> [ServerProfile] {
            profiles
        }

        func saveProfiles(_: [ServerProfile]) throws {}
        func loadSelectedProfileID() throws -> UUID? {
            selectedProfileID
        }

        func saveSelectedProfileID(_: UUID?) throws {}
    }

    struct PreviewTokenStore: TokenStore {
        func token(for _: UUID) async throws -> String? {
            nil
        }

        func save(_: String, for _: UUID) async throws {}
        func deleteToken(for _: UUID) async throws {}
    }

    struct PreviewCapabilityProbe: CapabilityProbing {
        var outcome: CompatibilityOutcome = .legacyFallback
        func probe(_: ServerProfile) async throws -> CompatibilityOutcome {
            outcome
        }
    }

    struct PreviewAuthenticating: AppAuthenticating {
        func authenticate(
            _: AuthenticationCredentials, on _: ServerProfile
        ) async throws -> AuthToken {
            AuthToken(token: "preview-token")
        }

        func register(_: RegistrationDetails, on _: ServerProfile) async throws -> AuthToken {
            AuthToken(token: "preview-token")
        }

        func currentUser(on _: ServerProfile, token _: String) async throws -> CurrentUser {
            .previewSample
        }
    }

    extension CurrentUser {
        static let previewSample = CurrentUser(
            username: "roland-banks", email: "roland@example.com", beta: false, admin: false
        )
    }

    /// Builds a preview-only ``AppModel`` backed entirely by in-memory fakes.
    @MainActor
    func previewAppModel(
        profiles: [ServerProfile] = [.hosted],
        selectedProfileID: UUID? = ServerProfile.hosted.id,
        outcome: CompatibilityOutcome = .legacyFallback
    ) -> AppModel {
        AppModel(
            profileStore: PreviewServerProfileStore(
                profiles: profiles, selectedProfileID: selectedProfileID
            ),
            tokenStore: PreviewTokenStore(),
            capabilityProbe: PreviewCapabilityProbe(outcome: outcome),
            authenticationSession: PreviewAuthenticating()
        )
    }
#endif
