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
        func deleteAllTokens() async throws {}
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

    /// A no-op ``TokenCleanupPendingStore`` for previews: never reports anything
    /// pending, so a preview never blocks on (or touches) real durable storage.
    struct PreviewTokenCleanupPendingStore: TokenCleanupPendingStore {
        func pendingProfileIDs() throws -> Set<UUID> {
            []
        }

        func markPending(_: UUID) throws {}
        func clearPending(_: UUID) throws {}
        func clearAll() throws {}
    }

    /// A ``GameLifecycleServicing`` fake for previews: returns a small, representative
    /// sample list and otherwise never touches the network.
    struct PreviewGameLifecycleService: GameLifecycleServicing {
        func listGames(on _: ServerProfile, token _: String) async throws -> GameList {
            [
                .game(
                    GameSummary(
                        id: GameID(UUID()),
                        scenario: ScenarioSummary(
                            id: "01104", difficulty: .easy,
                            name: CardName(title: "The Gathering", subtitle: nil), variant: nil
                        ),
                        campaign: nil,
                        gameState: .active,
                        name: "Preview solo game",
                        investigators: [
                            InvestigatorSummary(id: "01001", classSymbol: .init("Guardian")),
                        ],
                        otherInvestigators: [],
                        multiplayerVariant: .solo,
                        hasOpenSeats: false
                    )
                ),
                .game(
                    GameSummary(
                        id: GameID(UUID()),
                        scenario: nil,
                        campaign: CampaignSummary(
                            id: "01", difficulty: .standard, currentCampaignMode: nil
                        ),
                        gameState: .pending([]),
                        name: "Preview campaign",
                        investigators: [],
                        otherInvestigators: [],
                        multiplayerVariant: .withFriends,
                        hasOpenSeats: true
                    )
                ),
            ]
        }

        func createGame(
            _: CreateGameRequest, on _: ServerProfile, token _: String
        ) async throws -> GameLifecycleEnvelope {
            .unsupported
        }

        func deleteGame(_: GameID, on _: ServerProfile, token _: String) async throws {}

        func peekLobby(
            _: GameID, on _: ServerProfile, token _: String
        ) async throws -> GameLifecycleEnvelope {
            .unsupported
        }

        func joinGame(
            _: GameID, on _: ServerProfile, token _: String
        ) async throws -> GameLifecycleEnvelope {
            .unsupported
        }

        func openSeats(
            for _: GameID, on _: ServerProfile, token _: String
        ) async throws -> OpenSeats {
            []
        }

        func claimSeat(
            _: ClaimSeatRequest, in _: GameID, on _: ServerProfile, token _: String
        ) async throws {}

        func chooseDeck(
            _: ChooseDeckRequest, in _: GameID, on _: ServerProfile, token _: String
        ) async throws {}
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
            authenticationSession: PreviewAuthenticating(),
            cleanupPendingStore: PreviewTokenCleanupPendingStore(),
            gameLifecycleService: PreviewGameLifecycleService()
        )
    }
#endif
