// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

/// A ``GameLifecycleServicing`` fake whose per-endpoint results are queued
/// (consumed FIFO, one per call) so a test can script an exact sequence of
/// successes/failures without a silent, success-shaped default: an endpoint called
/// more times than results were queued for it throws ``TestFailure`` rather than
/// quietly returning a made-up value.
///
/// `listGames` additionally supports gating (suspending every call on a queue of
/// continuations resumable in any order) so refresh overlap/reordering can be
/// exercised deterministically -- mirroring ``GatedCapabilityProbe``'s pattern.
actor ScriptedGameLifecycleService: GameLifecycleServicing {
    // swiftlint:disable:previous type_body_length
    private(set) var callOrder: [String] = []
    private(set) var lastToken: String?
    private(set) var lastProfileID: UUID?
    private(set) var lastDeletedGameID: GameID?
    private(set) var lastPeekLobbyGameID: GameID?
    private(set) var lastJoinGameID: GameID?
    private(set) var lastOpenSeatsGameID: GameID?
    private(set) var lastClaimSeatGameID: GameID?
    private(set) var lastClaimSeatRequest: ClaimSeatRequest?
    private(set) var lastChooseDeckRequest: ChooseDeckRequest?
    private(set) var lastCreateGameRequest: CreateGameRequest?

    private var listGamesQueue: [Result<GameList, any Error>] = []
    private var createGameQueue: [Result<GameLifecycleEnvelope, any Error>] = []
    private var deleteGameQueue: [Result<Void, any Error>] = []
    private var getGameQueue: [Result<GetGameEnvelope, any Error>] = []
    private var peekLobbyQueue: [Result<GameLifecyclePreview, any Error>] = []
    private var joinGameQueue: [Result<GameLifecycleEnvelope, any Error>] = []
    private var openSeatsQueue: [Result<OpenSeats, any Error>] = []
    private var claimSeatQueue: [Result<Void, any Error>] = []
    private var chooseDeckQueue: [Result<Void, any Error>] = []

    private var isListGamesGated = false
    private var listGamesContinuations: [CheckedContinuation<GameList, any Error>] = []
    private var listGamesPendingWaiters: [
        (threshold: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    private var isPeekLobbyGated = false
    private var peekLobbyContinuations: [CheckedContinuation<GameLifecyclePreview, any Error>] = []
    private var peekLobbyPendingWaiters: [
        (threshold: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    private var isJoinGameGated = false
    private var joinGameContinuations: [CheckedContinuation<GameLifecycleEnvelope, any Error>] = []
    private var joinGamePendingWaiters: [
        (threshold: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    private var isOpenSeatsGated = false
    private var openSeatsContinuations: [CheckedContinuation<OpenSeats, any Error>] = []
    private var openSeatsPendingWaiters: [
        (threshold: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    private var isDeleteGameGated = false
    private var deleteGameContinuations: [GameLifecycleVoidContinuation] = []
    private var deleteGamePendingWaiters: [
        (threshold: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    private var isChooseDeckGated = false
    private var chooseDeckContinuations: [GameLifecycleVoidContinuation] = []
    private var chooseDeckPendingWaiters: [
        (threshold: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    private var isClaimSeatGated = false
    private var claimSeatContinuations: [GameLifecycleVoidContinuation] = []
    private var claimSeatPendingWaiters: [
        (threshold: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    private var isGetGameGated = false
    private var getGameContinuations: [CheckedContinuation<GetGameEnvelope, any Error>] = []
    private var getGamePendingWaiters: [
        (threshold: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    private(set) var lastGetGameGameID: GameID?

    // MARK: - Scripting

    func enqueueListGamesResult(_ result: Result<GameList, any Error>) {
        listGamesQueue.append(result)
    }

    func enqueueCreateGameResult(_ result: Result<GameLifecycleEnvelope, any Error>) {
        createGameQueue.append(result)
    }

    func enqueueDeleteGameResult(_ result: Result<Void, any Error>) {
        deleteGameQueue.append(result)
    }

    func enqueueGetGameResult(_ result: Result<GetGameEnvelope, any Error>) {
        getGameQueue.append(result)
    }

    func enqueuePeekLobbyResult(_ result: Result<GameLifecyclePreview, any Error>) {
        peekLobbyQueue.append(result)
    }

    func enqueueJoinGameResult(_ result: Result<GameLifecycleEnvelope, any Error>) {
        joinGameQueue.append(result)
    }

    func enqueueOpenSeatsResult(_ result: Result<OpenSeats, any Error>) {
        openSeatsQueue.append(result)
    }

    func enqueueClaimSeatResult(_ result: Result<Void, any Error>) {
        claimSeatQueue.append(result)
    }

    func enqueueChooseDeckResult(_ result: Result<Void, any Error>) {
        chooseDeckQueue.append(result)
    }

    func setListGamesGated(_ gated: Bool) {
        isListGamesGated = gated
    }

    func setPeekLobbyGated(_ gated: Bool) {
        isPeekLobbyGated = gated
    }

    func setJoinGameGated(_ gated: Bool) {
        isJoinGameGated = gated
    }

    func setOpenSeatsGated(_ gated: Bool) {
        isOpenSeatsGated = gated
    }

    func setDeleteGameGated(_ gated: Bool) {
        isDeleteGameGated = gated
    }

    func setChooseDeckGated(_ gated: Bool) {
        isChooseDeckGated = gated
    }

    func setClaimSeatGated(_ gated: Bool) {
        isClaimSeatGated = gated
    }

    func setGetGameGated(_ gated: Bool) {
        isGetGameGated = gated
    }

    /// Suspends until at least `count` `listGames` calls are simultaneously pending.
    func waitUntilListGamesPending(_ count: Int) async {
        if listGamesContinuations.count >= count {
            return
        }
        await withCheckedContinuation { listGamesPendingWaiters.append((count, $0)) }
    }

    /// Resumes the oldest (first-issued) still-pending `listGames` call.
    func resumeOldestListGames(with result: Result<GameList, any Error>) {
        guard !listGamesContinuations.isEmpty else { return }
        resume(listGamesContinuations.removeFirst(), with: result)
    }

    /// Resumes the newest (most-recently-issued) still-pending `listGames` call.
    func resumeNewestListGames(with result: Result<GameList, any Error>) {
        guard !listGamesContinuations.isEmpty else { return }
        resume(listGamesContinuations.removeLast(), with: result)
    }

    /// Suspends until at least `count` `peekLobby` calls are simultaneously pending.
    func waitUntilPeekLobbyPending(_ count: Int) async {
        if peekLobbyContinuations.count >= count {
            return
        }
        await withCheckedContinuation { peekLobbyPendingWaiters.append((count, $0)) }
    }

    /// Resumes the oldest (first-issued) still-pending `peekLobby` call.
    func resumeOldestPeekLobby(with result: Result<GameLifecyclePreview, any Error>) {
        guard !peekLobbyContinuations.isEmpty else { return }
        resume(peekLobbyContinuations.removeFirst(), with: result)
    }

    /// Suspends until at least `count` `joinGame` calls are simultaneously pending.
    func waitUntilJoinGamePending(_ count: Int) async {
        if joinGameContinuations.count >= count {
            return
        }
        await withCheckedContinuation { joinGamePendingWaiters.append((count, $0)) }
    }

    /// Resumes the oldest (first-issued) still-pending `joinGame` call.
    func resumeOldestJoinGame(with result: Result<GameLifecycleEnvelope, any Error>) {
        guard !joinGameContinuations.isEmpty else { return }
        resume(joinGameContinuations.removeFirst(), with: result)
    }

    /// Suspends until at least `count` `openSeats` calls are simultaneously pending.
    func waitUntilOpenSeatsPending(_ count: Int) async {
        if openSeatsContinuations.count >= count {
            return
        }
        await withCheckedContinuation { openSeatsPendingWaiters.append((count, $0)) }
    }

    /// Resumes the oldest (first-issued) still-pending `openSeats` call.
    func resumeOldestOpenSeats(with result: Result<OpenSeats, any Error>) {
        guard !openSeatsContinuations.isEmpty else { return }
        resume(openSeatsContinuations.removeFirst(), with: result)
    }

    /// Suspends until at least `count` `deleteGame` calls are simultaneously pending.
    func waitUntilDeleteGamePending(_ count: Int) async {
        if deleteGameContinuations.count >= count {
            return
        }
        await withCheckedContinuation { deleteGamePendingWaiters.append((count, $0)) }
    }

    /// Resumes the oldest (first-issued) still-pending `deleteGame` call.
    func resumeOldestDeleteGame(with result: Result<Void, any Error>) {
        guard !deleteGameContinuations.isEmpty else { return }
        let continuation = deleteGameContinuations.removeFirst()
        switch result {
        case .success: continuation.resume(returning: ())
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    /// Suspends until at least `count` `chooseDeck` calls are simultaneously pending.
    func waitUntilChooseDeckPending(_ count: Int) async {
        if chooseDeckContinuations.count >= count {
            return
        }
        await withCheckedContinuation { chooseDeckPendingWaiters.append((count, $0)) }
    }

    /// Resumes the oldest (first-issued) still-pending `chooseDeck` call.
    func resumeOldestChooseDeck(with result: Result<Void, any Error>) {
        guard !chooseDeckContinuations.isEmpty else { return }
        let continuation = chooseDeckContinuations.removeFirst()
        switch result {
        case .success: continuation.resume(returning: ())
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    /// Suspends until at least `count` `claimSeat` calls are simultaneously pending.
    func waitUntilClaimSeatPending(_ count: Int) async {
        if claimSeatContinuations.count >= count {
            return
        }
        await withCheckedContinuation { claimSeatPendingWaiters.append((count, $0)) }
    }

    /// Resumes the oldest (first-issued) still-pending `claimSeat` call.
    func resumeOldestClaimSeat(with result: Result<Void, any Error>) {
        guard !claimSeatContinuations.isEmpty else { return }
        let continuation = claimSeatContinuations.removeFirst()
        switch result {
        case .success: continuation.resume(returning: ())
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    /// Suspends until at least `count` `getGame` calls are simultaneously pending.
    func waitUntilGetGamePending(_ count: Int) async {
        if getGameContinuations.count >= count {
            return
        }
        await withCheckedContinuation { getGamePendingWaiters.append((count, $0)) }
    }

    /// Resumes the oldest (first-issued) still-pending `getGame` call.
    func resumeOldestGetGame(with result: Result<GetGameEnvelope, any Error>) {
        guard !getGameContinuations.isEmpty else { return }
        let continuation = getGameContinuations.removeFirst()
        switch result {
        case let .success(value): continuation.resume(returning: value)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    /// Resumes the newest (most-recently-issued) still-pending `getGame` call.
    func resumeNewestGetGame(with result: Result<GetGameEnvelope, any Error>) {
        guard !getGameContinuations.isEmpty else { return }
        let continuation = getGameContinuations.removeLast()
        switch result {
        case let .success(value): continuation.resume(returning: value)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    private func resume<T: Sendable>(
        _ continuation: CheckedContinuation<T, any Error>,
        with result: Result<T, any Error>
    ) {
        switch result {
        case let .success(value): continuation.resume(returning: value)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    private func notifyListGamesWaiters() {
        listGamesPendingWaiters.removeAll { entry in
            guard listGamesContinuations.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }

    private func notifyPeekLobbyWaiters() {
        peekLobbyPendingWaiters.removeAll { entry in
            guard peekLobbyContinuations.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }

    private func notifyJoinGameWaiters() {
        joinGamePendingWaiters.removeAll { entry in
            guard joinGameContinuations.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }

    private func notifyOpenSeatsWaiters() {
        openSeatsPendingWaiters.removeAll { entry in
            guard openSeatsContinuations.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }

    private func notifyDeleteGameWaiters() {
        deleteGamePendingWaiters.removeAll { entry in
            guard deleteGameContinuations.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }

    private func notifyChooseDeckWaiters() {
        chooseDeckPendingWaiters.removeAll { entry in
            guard chooseDeckContinuations.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }

    private func notifyClaimSeatWaiters() {
        claimSeatPendingWaiters.removeAll { entry in
            guard claimSeatContinuations.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }

    private func notifyGetGameWaiters() {
        getGamePendingWaiters.removeAll { entry in
            guard getGameContinuations.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }

    /// Suspends the caller until this gated `deleteGame` call is resumed, appending
    /// its continuation and notifying any waiter. Extracted into its own method
    /// (rather than an inline closure at `deleteGame`'s own call site) purely so the
    /// closure's parameter list fits on the same line as its opening brace at this
    /// shallower indentation.
    private func awaitDeleteGameGate() async throws {
        try await withCheckedThrowingContinuation { (continuation: GameLifecycleVoidContinuation) in
            deleteGameContinuations.append(continuation)
            notifyDeleteGameWaiters()
        }
    }

    private func awaitChooseDeckGate() async throws {
        try await withCheckedThrowingContinuation { (continuation: GameLifecycleVoidContinuation) in
            chooseDeckContinuations.append(continuation)
            notifyChooseDeckWaiters()
        }
    }

    private func awaitClaimSeatGate() async throws {
        try await withCheckedThrowingContinuation { (continuation: GameLifecycleVoidContinuation) in
            claimSeatContinuations.append(continuation)
            notifyClaimSeatWaiters()
        }
    }

    private func consume<T>(_ queue: inout [Result<T, any Error>]) throws -> T {
        guard !queue.isEmpty else { throw TestFailure() }
        return try queue.removeFirst().get()
    }

    // MARK: - GameLifecycleServicing

    func listGames(on profile: ServerProfile, token: String) async throws -> GameList {
        callOrder.append("listGames")
        lastToken = token
        lastProfileID = profile.id
        if isListGamesGated {
            return try await withCheckedThrowingContinuation { continuation in
                listGamesContinuations.append(continuation)
                notifyListGamesWaiters()
            }
        }
        return try consume(&listGamesQueue)
    }

    func createGame(
        _ request: CreateGameRequest, on profile: ServerProfile, token: String
    ) async throws -> GameLifecycleEnvelope {
        callOrder.append("createGame")
        lastToken = token
        lastProfileID = profile.id
        lastCreateGameRequest = request
        return try consume(&createGameQueue)
    }

    func deleteGame(_ id: GameID, on profile: ServerProfile, token: String) async throws {
        callOrder.append("deleteGame")
        lastToken = token
        lastProfileID = profile.id
        lastDeletedGameID = id
        if isDeleteGameGated {
            try await awaitDeleteGameGate()
            return
        }
        try consume(&deleteGameQueue)
    }

    func getGame(
        _ id: GameID, on profile: ServerProfile, token: String
    ) async throws -> GetGameEnvelope {
        callOrder.append("getGame")
        lastToken = token
        lastProfileID = profile.id
        lastGetGameGameID = id
        if isGetGameGated {
            return try await withCheckedThrowingContinuation { continuation in
                getGameContinuations.append(continuation)
                notifyGetGameWaiters()
            }
        }
        return try consume(&getGameQueue)
    }

    func peekLobby(
        _ id: GameID, on profile: ServerProfile, token: String
    ) async throws -> GameLifecyclePreview {
        callOrder.append("peekLobby")
        lastToken = token
        lastProfileID = profile.id
        lastPeekLobbyGameID = id
        if isPeekLobbyGated {
            return try await withCheckedThrowingContinuation { continuation in
                peekLobbyContinuations.append(continuation)
                notifyPeekLobbyWaiters()
            }
        }
        return try consume(&peekLobbyQueue)
    }

    func joinGame(
        _ id: GameID, on profile: ServerProfile, token: String
    ) async throws -> GameLifecycleEnvelope {
        callOrder.append("joinGame")
        lastToken = token
        lastProfileID = profile.id
        lastJoinGameID = id
        if isJoinGameGated {
            return try await withCheckedThrowingContinuation { continuation in
                joinGameContinuations.append(continuation)
                notifyJoinGameWaiters()
            }
        }
        return try consume(&joinGameQueue)
    }

    func openSeats(
        for id: GameID, on profile: ServerProfile, token: String
    ) async throws -> OpenSeats {
        callOrder.append("openSeats")
        lastToken = token
        lastProfileID = profile.id
        lastOpenSeatsGameID = id
        if isOpenSeatsGated {
            return try await withCheckedThrowingContinuation { continuation in
                openSeatsContinuations.append(continuation)
                notifyOpenSeatsWaiters()
            }
        }
        return try consume(&openSeatsQueue)
    }

    func claimSeat(
        _ request: ClaimSeatRequest, in id: GameID, on profile: ServerProfile, token: String
    ) async throws {
        callOrder.append("claimSeat")
        lastToken = token
        lastProfileID = profile.id
        lastClaimSeatGameID = id
        lastClaimSeatRequest = request
        if isClaimSeatGated {
            try await awaitClaimSeatGate()
            return
        }
        try consume(&claimSeatQueue)
    }

    func chooseDeck(
        _ request: ChooseDeckRequest, in _: GameID, on profile: ServerProfile, token: String
    ) async throws {
        callOrder.append("chooseDeck")
        lastToken = token
        lastProfileID = profile.id
        lastChooseDeckRequest = request
        if isChooseDeckGated {
            try await awaitChooseDeckGate()
            return
        }
        try consume(&chooseDeckQueue)
    }
}

/// Test-only helpers for reaching a signed-in ``AppModel`` deterministically, shared
/// by every game-lifecycle test file.
enum GameLifecycleTestModel {
    /// Builds and awaits a signed-in ``AppModel`` for ``ServerProfile/hosted``, backed
    /// entirely by in-memory fakes, with `gameService` as its game-lifecycle client.
    @MainActor
    static func makeSignedIn(
        gameService: ScriptedGameLifecycleService,
        token: String = "session-token"
    ) async -> AppModel {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: token])
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: gameService
        )
        await model.flowTask?.value
        return model
    }
}
