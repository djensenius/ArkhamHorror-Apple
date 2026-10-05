@testable import ArkhamHorrorShared
import Foundation
import SwiftUI
import Testing

/// Platform-neutral presentation-layer coverage for the games list/lobby surface.
///
/// This deliberately stays at a stable layer rather than pixel/snapshot testing:
/// each test constructs a view for a specific ``GameListLoadState``/game state and
/// forces its `body` to evaluate (proving every `switch`/`if case` branch in
/// `GamesListView`/`GameRowView`/`GameLobbyView` actually type-checks and runs
/// without crashing for that state), and separately asserts the accessibility
/// identifiers/labels those views attach are the stable, documented ones
/// `AppModel`/`AccountAccessibilityID` already expose -- never asserting on layout,
/// color, or exact frame geometry.
@MainActor
@Suite("Games list/lobby presentation")
struct GamesListPresentationTests {
    private func sampleGame(
        id: GameID = GameID(UUID()),
        gameState: GameState = .active,
        investigators: [InvestigatorSummary] = [],
        multiplayerVariant: MultiplayerVariant = .solo,
        hasOpenSeats: Bool = false
    ) -> GameSummary {
        GameSummary(
            id: id, scenario: nil, campaign: nil, gameState: gameState,
            name: "Sample", investigators: investigators, otherInvestigators: [],
            multiplayerVariant: multiplayerVariant, hasOpenSeats: hasOpenSeats
        )
    }

    private func model(gameListState: GameListLoadState) async -> AppModel {
        let service = ScriptedGameLifecycleService()
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        model.gameListState = gameListState
        return model
    }

    private final class ChangeCounter: @unchecked Sendable {
        private(set) var count = 0

        func increment() {
            count += 1
        }
    }

    // MARK: - GamesListView body evaluates for every load state

    @Test("GamesListView's body evaluates for .idle without crashing")
    func gamesListViewIdle() async {
        let model = await model(gameListState: .idle)
        let view = GamesListView(model: model)
        _ = view.body
    }

    @Test("GamesListView's body evaluates for .loading(previous: nil) without crashing")
    func gamesListViewLoadingEmpty() async {
        let model = await model(gameListState: .loading(previous: nil))
        let view = GamesListView(model: model)
        _ = view.body
    }

    @Test("GamesListView's body evaluates for .loading with prior content without crashing")
    func gamesListViewLoadingWithPrevious() async {
        let games: GameList = [.game(sampleGame())]
        let model = await model(gameListState: .loading(previous: games))
        let view = GamesListView(model: model)
        _ = view.body
    }

    @Test("GamesListView's body evaluates for an empty .loaded list without crashing")
    func gamesListViewLoadedEmpty() async {
        let model = await model(gameListState: .loaded([]))
        let view = GamesListView(model: model)
        _ = view.body
    }

    @Test("GamesListView renders a populated .loaded list including a failed row")
    func gamesListViewLoadedPopulated() async {
        let games: GameList = [
            .game(sampleGame()), .failed(FailedGameEntry(error: "Could not load this game.")),
        ]
        let model = await model(gameListState: .loaded(games))
        let view = GamesListView(model: model)
        _ = view.body
    }

    @Test(
        """
        GamesListView's body evaluates without crashing for a row whose per-game \
        lifecycle action is in flight (its swipe/context-menu delete must disable, \
        never trigger a second, superseding action)
        """
    )
    func gamesListViewRowWithActionInFlight() async {
        let game = sampleGame()
        let model = await model(gameListState: .loaded([.game(game)]))
        model.gameLifecycleActions[game.id] = .joining
        let view = GamesListView(model: model)
        _ = view.body
    }

    @Test("Final delete confirmation disables while that game has an action in flight")
    func deleteConfirmationDisabledWhenActionInFlight() async {
        let game = sampleGame()
        let model = await model(gameListState: .loaded([.game(game)]))
        let view = GamesListView(model: model)

        #expect(!view.isDeleteConfirmationDisabled(for: game.id))
        model.gameLifecycleActions[game.id] = .joining
        #expect(view.isDeleteConfirmationDisabled(for: game.id))
    }

    @Test("GamesListView's body evaluates for .failed with no previous content without crashing")
    func gamesListViewFailedNoPrevious() async {
        let model = await model(gameListState: .failed(.transportFailure("x"), previous: nil))
        let view = GamesListView(model: model)
        _ = view.body
    }

    @Test("GamesListView renders .failed with prior content still visible")
    func gamesListViewFailedWithPrevious() async {
        let games: GameList = [.game(sampleGame())]
        let model = await model(gameListState: .failed(.unexpectedStatus(500), previous: games))
        let view = GamesListView(model: model)
        _ = view.body
    }

    @Test("GamesListView observes confirmed deletes independently of game-list state")
    func gamesListViewBodyObservesConfirmedDeletes() async {
        let model = await model(gameListState: .loading(previous: [.game(sampleGame())]))
        let view = GamesListView(model: model)
        let counter = ChangeCounter()

        withObservationTracking {
            _ = view.body
        } onChange: {
            counter.increment()
        }
        model.confirmedDeletedGameIDs.insert(GameID(UUID()))

        #expect(counter.count == 1)
    }

    @Test("Create-game handoff opens the lobby only after the create sheet dismisses")
    func createGameHandoffWaitsForDismissal() {
        var handoff = CreateGameLobbyHandoff()
        #expect(handoff.completedDismissal() == nil)

        let gameID = GameID(UUID())
        handoff.created(gameID)
        #expect(handoff.pendingGameID == gameID)
        #expect(handoff.completedDismissal() == gameID)
        #expect(handoff.pendingGameID == nil)
        #expect(handoff.completedDismissal() == nil)
    }

    @Test(
        """
        identifiedRows keys a .game row by its own GameID and a .failed row by \
        position, never index for a .game row
        """
    )
    func identifiedRowsUseStableGameIDIdentity() async {
        let firstGame = sampleGame()
        let secondGame = sampleGame()
        let games: GameList = [
            .game(firstGame),
            .failed(FailedGameEntry(error: "Could not load this game.")),
            .game(secondGame),
        ]
        let model = await model(gameListState: .loaded(games))
        let view = GamesListView(model: model)
        let rows = view.identifiedRows(for: games)

        #expect(rows.map(\.id) == [
            AnyHashable(firstGame.id), AnyHashable(1), AnyHashable(secondGame.id),
        ])
    }

    @Test("Only active games navigate directly from the games list")
    func gamesListRoutingDecision() {
        #expect(GameState.active.opensLiveGameView)
        #expect(!GameState.chooseDecks([PlayerID(UUID())]).opensLiveGameView)
        #expect(!GameState.pending([]).opensLiveGameView)
        #expect(!GameState.over.opensLiveGameView)
    }

    // MARK: - GameRowView body evaluates for every notable game shape

    @Test("GameRowView's body evaluates for a plain solo game without crashing")
    func gameRowViewSolo() {
        let view = GameRowView(game: sampleGame())
        _ = view.body
    }

    @Test("GameRowView renders a game with investigators and an open seat")
    func gameRowViewWithInvestigatorsAndOpenSeat() {
        let investigators = [
            InvestigatorSummary(id: "01001", classSymbol: .init("Guardian")),
            InvestigatorSummary(id: "01002", classSymbol: .init("Seeker")),
        ]
        let view = GameRowView(
            game: sampleGame(
                gameState: .pending([]), investigators: investigators,
                multiplayerVariant: .withFriends, hasOpenSeats: true
            )
        )
        _ = view.body
    }

    // MARK: - AccountShellView body evaluates for the signed-in shell

    @Test("AccountShellView's body evaluates for a signed-in user without crashing")
    func accountShellViewSignedIn() async {
        let model = await model(gameListState: .loaded([]))
        let view = AccountShellView(
            model: model, profile: .hosted, compatibility: .legacy, user: .sample
        )
        _ = view.body
    }

    // MARK: - Stable accessibility identifiers

    @Test("Every games-list/lobby accessibility identifier is stable, non-empty, and unique")
    func gamesAccessibilityIdentifiersAreStableAndUnique() {
        let gameID = UUID()
        let identifiers = [
            AccountAccessibilityID.gamesRefreshButton,
            AccountAccessibilityID.gamesRetryButton,
            AccountAccessibilityID.createGameOpenButton,
            AccountAccessibilityID.createGameSheet,
            AccountAccessibilityID.createGameModePicker,
            AccountAccessibilityID.createGameCatalogPicker,
            AccountAccessibilityID.createGameDifficultyPicker,
            AccountAccessibilityID.createGamePlayerCountPicker,
            AccountAccessibilityID.createGameVariantPicker,
            AccountAccessibilityID.createGameNameField,
            AccountAccessibilityID.createGameSubmitButton,
            AccountAccessibilityID.createGameCancelButton,
            AccountAccessibilityID.createGameFailureText,
            AccountAccessibilityID.gameDeleteConfirmButton,
            AccountAccessibilityID.gameListFailureText,
            AccountAccessibilityID.accountDetailButton,
            AccountAccessibilityID.gameRow(for: gameID),
            AccountAccessibilityID.gameDeleteButton(for: gameID),
            AccountAccessibilityID.gameJoinButton(for: gameID),
            AccountAccessibilityID.gameOpenSeatsButton(for: gameID),
            AccountAccessibilityID.gameClaimSeatButton(for: gameID, seat: "c01001"),
            AccountAccessibilityID.gameContinueDeckButton(for: gameID, investigatorId: "01001"),
            AccountAccessibilityID.gameActionFailureText(for: gameID),
            AccountAccessibilityID.liveGameRetryButton,
            AccountAccessibilityID.liveGameDismissButton,
            AccountAccessibilityID.liveGameLoadingText,
            AccountAccessibilityID.liveGameReconnectingText,
            AccountAccessibilityID.liveGameOfflineText,
            AccountAccessibilityID.liveGameIncompatiblePayloadText,
            AccountAccessibilityID.liveGameAuthenticationExpiredText,
            AccountAccessibilityID.liveGameTerminalFailureText,
            AccountAccessibilityID.liveGameEnterButton(for: gameID),
        ]
        #expect(identifiers.allSatisfy { !$0.isEmpty })
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test("Per-game accessibility identifiers are distinct across different game IDs")
    func perGameAccessibilityIdentifiersDifferByGameID() {
        let first = UUID()
        let second = UUID()
        let firstRow = AccountAccessibilityID.gameRow(for: first)
        let secondRow = AccountAccessibilityID.gameRow(for: second)
        #expect(firstRow != secondRow)
        #expect(
            AccountAccessibilityID.gameDeleteButton(for: first)
                != AccountAccessibilityID.gameDeleteButton(for: second)
        )
        #expect(
            AccountAccessibilityID.gameActionFailureText(for: first)
                != AccountAccessibilityID.gameActionFailureText(for: second)
        )
        #expect(
            AccountAccessibilityID.liveGameEnterButton(for: first)
                != AccountAccessibilityID.liveGameEnterButton(for: second)
        )
    }
}

extension GamesListPresentationTests {
    @Test("Final delete confirmation action does not supersede an in-flight game action")
    func deleteConfirmationActionGuardsWhenActionInFlight() async {
        let game = sampleGame()
        let model = await model(gameListState: .loaded([.game(game)]))
        model.gameLifecycleActions[game.id] = .joining
        let view = GamesListView(model: model)

        view.confirmDeletion(of: game.id)

        #expect(model.gameLifecycleActions[game.id] == .joining)
        #expect(model.gameLifecycleActionTasks[game.id] == nil)
    }

    @Test("Confirmed-deleted games are hidden from preserved and loaded visible rows")
    func confirmedDeletedRowsAreHiddenFromVisibleRows() async throws {
        let deleted = sampleGame()
        let remaining = sampleGame()
        let failed = FailedGameEntry(error: "Could not decode a game.")
        let staleList: GameList = [.game(deleted), .failed(failed), .game(remaining)]
        let refreshedList: GameList = [.failed(failed), .game(remaining)]
        let expectedVisibleRows: GameList = [.failed(failed), .game(remaining)]

        let states: [GameListLoadState] = [
            .loading(previous: staleList),
            .failed(.unexpectedStatus(500), previous: staleList),
            .loaded(refreshedList),
        ]

        for state in states {
            let model = await model(gameListState: state)
            model.confirmedDeletedGameIDs = [deleted.id]
            let view = GamesListView(model: model)
            let rows = try #require(visibleEntries(from: state, in: view))

            #expect(rows == expectedVisibleRows)
        }
    }

    private func visibleEntries(
        from state: GameListLoadState,
        in view: GamesListView
    ) -> GameList? {
        switch state {
        case .idle:
            nil
        case let .loading(previous):
            previous.map { view.visibleRows(for: $0).map(\.entry) }
        case let .loaded(games):
            view.visibleRows(for: games).map(\.entry)
        case let .failed(_, previous):
            previous.map { view.visibleRows(for: $0).map(\.entry) }
        }
    }

    @Test("Delete failures produce row-local server message presentation")
    func deleteFailurePresentationUsesServerMessageVerbatim() async throws {
        let game = sampleGame()
        let serverMessage = "Delete is disabled while this game is being updated."
        let model = await model(gameListState: .loaded([.game(game)]))
        model.gameLifecycleActionFailures[game.id] = GameLifecycleActionFailure(
            action: .deleting,
            error: .operationFailed(DeckOperationError(errorMsg: serverMessage))
        )
        let view = GamesListView(model: model)

        let presentation = try #require(view.deleteFailurePresentation(for: game.id))
        #expect(presentation.message == serverMessage)
        #expect(
            presentation.accessibilityIdentifier
                == AccountAccessibilityID.gameActionFailureText(for: game.id.rawValue)
        )
        #expect(presentation.accessibilityLabel.contains(serverMessage))
        _ = GameRowView(game: game, actionFailure: presentation).body
    }

    @Test("Only delete failures produce games-list row failure presentation")
    func rowFailurePresentationIsScopedToDeleteFailures() async {
        let game = sampleGame()
        let model = await model(gameListState: .loaded([.game(game)]))
        model.gameLifecycleActionFailures[game.id] = GameLifecycleActionFailure(
            action: .joining,
            error: .unexpectedStatus(409)
        )
        let view = GamesListView(model: model)

        #expect(view.deleteFailurePresentation(for: game.id) == nil)
    }
}
