/// A narrow, injectable capability-probing interface used by the session coordinator.
///
/// ``CapabilityProbe`` is the production conformance. Tests inject a deterministic fake
/// so the coordinator's compatibility handling can be exercised without real network I/O.
protocol CapabilityProbing: Sendable {
    /// Probes `profile` and returns its compatibility outcome.
    ///
    /// - Throws: ``CapabilityProbeError`` for observable probe failures; rethrows
    ///   `CancellationError` when the task is cancelled.
    func probe(_ profile: ServerProfile) async throws -> CompatibilityOutcome
}

extension CapabilityProbe: CapabilityProbing {}

/// A narrow, injectable authentication interface used by the session coordinator.
///
/// ``AuthenticationSession`` is the production conformance. Tests inject a deterministic
/// fake so sign-in, registration, and token-validation flows can be exercised without
/// real network I/O.
protocol AppAuthenticating: Sendable {
    /// Exchanges credentials for a token. Never durably persisted by this call alone.
    func authenticate(
        _ credentials: AuthenticationCredentials,
        on profile: ServerProfile
    ) async throws -> AuthToken

    /// Creates an account and returns a token. Never durably persisted by this call alone.
    func register(
        _ details: RegistrationDetails,
        on profile: ServerProfile
    ) async throws -> AuthToken

    /// Validates `token` and returns the authenticated account.
    ///
    /// - Throws: ``AuthenticationError/unauthorized`` when the server explicitly rejects
    ///   the token; another ``AuthenticationError`` for transient failures.
    func currentUser(on profile: ServerProfile, token: String) async throws -> CurrentUser
}

extension AuthenticationSession: AppAuthenticating {}

/// A narrow, injectable authenticated game-lifecycle interface used by `AppModel`'s
/// game-list/lobby coordinator.
///
/// ``GameLifecycleService`` is the production conformance. Tests inject a deterministic
/// fake so list/create/delete/join/claim-seat/choose-deck handling can be exercised
/// without real network I/O. Every method requires a bearer `token` and sets exactly
/// `Authorization: Token <token>`; there is no public (unauthenticated) operation here.
protocol GameLifecycleServicing: Sendable {
    /// Lists every game visible to the authenticated account via `GET /arkham/games`.
    func listGames(on profile: ServerProfile, token: String) async throws -> GameList

    /// Creates a new game via `POST /arkham/games`.
    ///
    /// Exposed for tests and a future option-driven create surface; this slice never
    /// presents a raw-ID creation form.
    func createGame(
        _ request: CreateGameRequest, on profile: ServerProfile, token: String
    ) async throws -> GameLifecycleEnvelope

    /// Deletes an owned game via `DELETE /arkham/games/:id`.
    func deleteGame(_ id: GameID, on profile: ServerProfile, token: String) async throws

    /// Previews a pending game's lobby via `GET /arkham/games/:id/join`, without
    /// joining it.
    func peekLobby(
        _ id: GameID, on profile: ServerProfile, token: String
    ) async throws -> GameLifecycleEnvelope

    /// Joins a pending game via `PUT /arkham/games/:id/join`.
    func joinGame(
        _ id: GameID, on profile: ServerProfile, token: String
    ) async throws -> GameLifecycleEnvelope

    /// Lists a game's unclaimed investigator seats via
    /// `GET /arkham/games/:id/open-seats`.
    func openSeats(
        for id: GameID, on profile: ServerProfile, token: String
    ) async throws -> OpenSeats

    /// Claims an open seat via `POST /arkham/games/:id/claim-seat`.
    func claimSeat(
        _ request: ClaimSeatRequest, in id: GameID, on profile: ServerProfile, token: String
    ) async throws

    /// Chooses (or replaces, or declines to upgrade) a claimed seat's deck via
    /// `PUT /arkham/games/:id/decks`.
    func chooseDeck(
        _ request: ChooseDeckRequest, in id: GameID, on profile: ServerProfile, token: String
    ) async throws
}

extension GameLifecycleService: GameLifecycleServicing {}
