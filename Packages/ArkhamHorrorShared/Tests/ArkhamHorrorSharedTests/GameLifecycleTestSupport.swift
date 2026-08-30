@testable import ArkhamHorrorShared
import Foundation
import Testing

// MARK: - HTTPTransport fakes shared by GameLifecycleService test files

/// Records the last request/body and returns a canned response.
actor GameLifecycleRecordingTransport: HTTPTransport {
    private(set) var capturedRequest: URLRequest?
    private(set) var capturedBody: Data?
    private let stubData: Data
    private let stubResponse: URLResponse

    init(data: Data, response: URLResponse) {
        stubData = data
        stubResponse = response
    }

    nonisolated func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await record(request)
        return (stubData, stubResponse)
    }

    private func record(_ request: URLRequest) {
        capturedRequest = request
        capturedBody = request.httpBody
    }
}

struct GameLifecycleFailingTransport: HTTPTransport {
    let error: any Error & Sendable
    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        throw error
    }
}

struct GameLifecycleTransportFailure: Error, Sendable {}

typealias GameLifecycleGateContinuation = CheckedContinuation<(Data, URLResponse), any Error>
typealias GameLifecycleVoidContinuation = CheckedContinuation<Void, any Error>

/// Blocks `data(for:)` until the caller releases the gate, so a task is guaranteed
/// mid-flight before cancellation is injected.
actor GameLifecycleGatedTransport: HTTPTransport {
    private var pendingGate: GameLifecycleGateContinuation?
    private var gateWaiter: CheckedContinuation<GameLifecycleGateContinuation, Never>?

    func awaitGate() async -> GameLifecycleGateContinuation {
        if let gate = pendingGate {
            pendingGate = nil
            return gate
        }
        return await withCheckedContinuation { gateWaiter = $0 }
    }

    private func deliverGate(_ gate: GameLifecycleGateContinuation) {
        if let waiter = gateWaiter {
            waiter.resume(returning: gate)
            gateWaiter = nil
        } else {
            pendingGate = gate
        }
    }

    nonisolated func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { gate in
            Task { await self.deliverGate(gate) }
        }
    }
}

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
    private(set) var callOrder: [String] = []
    private(set) var lastToken: String?
    private(set) var lastProfileID: UUID?
    private(set) var lastDeletedGameID: GameID?
    private(set) var lastClaimSeatRequest: ClaimSeatRequest?
    private(set) var lastChooseDeckRequest: ChooseDeckRequest?
    private(set) var lastCreateGameRequest: CreateGameRequest?

    private var listGamesQueue: [Result<GameList, any Error>] = []
    private var createGameQueue: [Result<GameLifecycleEnvelope, any Error>] = []
    private var deleteGameQueue: [Result<Void, any Error>] = []
    private var peekLobbyQueue: [Result<GameLifecycleEnvelope, any Error>] = []
    private var joinGameQueue: [Result<GameLifecycleEnvelope, any Error>] = []
    private var openSeatsQueue: [Result<OpenSeats, any Error>] = []
    private var claimSeatQueue: [Result<Void, any Error>] = []
    private var chooseDeckQueue: [Result<Void, any Error>] = []

    private var isListGamesGated = false
    private var listGamesContinuations: [CheckedContinuation<GameList, any Error>] = []
    private var listGamesPendingWaiters: [
        (threshold: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    private var isDeleteGameGated = false
    private var deleteGameContinuations: [GameLifecycleVoidContinuation] = []
    private var deleteGamePendingWaiters: [
        (threshold: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

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

    func enqueuePeekLobbyResult(_ result: Result<GameLifecycleEnvelope, any Error>) {
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

    func setDeleteGameGated(_ gated: Bool) {
        isDeleteGameGated = gated
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

    private func resume(
        _ continuation: CheckedContinuation<GameList, any Error>,
        with result: Result<GameList, any Error>
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

    private func notifyDeleteGameWaiters() {
        deleteGamePendingWaiters.removeAll { entry in
            guard deleteGameContinuations.count >= entry.threshold else { return false }
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

    func peekLobby(
        _: GameID, on profile: ServerProfile, token: String
    ) async throws -> GameLifecycleEnvelope {
        callOrder.append("peekLobby")
        lastToken = token
        lastProfileID = profile.id
        return try consume(&peekLobbyQueue)
    }

    func joinGame(
        _: GameID, on profile: ServerProfile, token: String
    ) async throws -> GameLifecycleEnvelope {
        callOrder.append("joinGame")
        lastToken = token
        lastProfileID = profile.id
        return try consume(&joinGameQueue)
    }

    func openSeats(
        for _: GameID, on profile: ServerProfile, token: String
    ) async throws -> OpenSeats {
        callOrder.append("openSeats")
        lastToken = token
        lastProfileID = profile.id
        return try consume(&openSeatsQueue)
    }

    func claimSeat(
        _ request: ClaimSeatRequest, in _: GameID, on profile: ServerProfile, token: String
    ) async throws {
        callOrder.append("claimSeat")
        lastToken = token
        lastProfileID = profile.id
        lastClaimSeatRequest = request
        try consume(&claimSeatQueue)
    }

    func chooseDeck(
        _ request: ChooseDeckRequest, in _: GameID, on profile: ServerProfile, token: String
    ) async throws {
        callOrder.append("chooseDeck")
        lastToken = token
        lastProfileID = profile.id
        lastChooseDeckRequest = request
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
