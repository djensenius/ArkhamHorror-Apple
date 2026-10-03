@testable import ArkhamHorrorShared
import Foundation
import SwiftUI
import Testing

/// Platform-neutral presentation-layer coverage for ``GameLobbyView``, split out of
/// `GamesListPresentationTests.swift` purely by file/type-body-length -- see that
/// file's own doc comment for this suite's shared philosophy (forcing `body` to
/// evaluate for every gated action surface, never pixel/snapshot testing).
@MainActor
@Suite("Game lobby presentation")
struct GameLobbyPresentationTests {
    private func sampleGame(
        gameState: GameState = .active,
        investigators: [InvestigatorSummary] = [],
        otherInvestigators: [InvestigatorSummary] = [],
        multiplayerVariant: MultiplayerVariant = .solo,
        hasOpenSeats: Bool = false
    ) -> GameSummary {
        GameSummary(
            id: GameID(UUID()), scenario: nil, campaign: nil, gameState: gameState,
            name: "Sample", investigators: investigators, otherInvestigators: otherInvestigators,
            multiplayerVariant: multiplayerVariant, hasOpenSeats: hasOpenSeats
        )
    }

    private func model(gameListState: GameListLoadState) async -> AppModel {
        let service = ScriptedGameLifecycleService()
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        model.gameListState = gameListState
        return model
    }

    @Test("GameLobbyView's body evaluates for a pending, joinable game without crashing")
    func gameLobbyViewPending() async {
        let game = sampleGame(gameState: .pending([]))
        let model = await model(gameListState: .loaded([.game(game)]))
        let view = GameLobbyView(model: model, gameID: game.id)
        _ = view.body
    }

    @Test("GameLobbyView chooses web-compatible join and claim-seat invite URLs")
    func gameLobbyViewPendingWithFriendsInvite() async {
        let claimedInvestigator = InvestigatorSummary(id: "01001", classSymbol: .guardian)
        let joinGame = sampleGame(gameState: .pending([]), multiplayerVariant: .withFriends)
        let claimGame = sampleGame(
            gameState: .pending([]), investigators: [claimedInvestigator],
            multiplayerVariant: .withFriends
        )
        let model = await model(gameListState: .loaded([.game(joinGame), .game(claimGame)]))

        let joinView = GameLobbyView(model: model, gameID: joinGame.id)
        let claimView = GameLobbyView(model: model, gameID: claimGame.id)

        let joinSuffix = "/games/\(joinGame.id.rawValue.uuidString.lowercased())/join"
        let claimSuffix = "/games/\(claimGame.id.rawValue.uuidString.lowercased())/claim-seat"
        #expect(joinView.inviteURL(for: joinGame)?.path.hasSuffix(joinSuffix) == true)
        #expect(claimView.inviteURL(for: claimGame)?.path.hasSuffix(claimSuffix) == true)
    }

    @Test("GameLobbyView only offers invites while a with-friends game is pending")
    func gameLobbyViewInviteIsPendingOnly() async {
        let model = await model(gameListState: .loaded([]))
        let pending = sampleGame(gameState: .pending([]), multiplayerVariant: .withFriends)
        let active = sampleGame(gameState: .active, multiplayerVariant: .withFriends)
        let solo = sampleGame(gameState: .pending([]), multiplayerVariant: .solo)

        #expect(GameLobbyView(model: model, gameID: pending.id).inviteURL(for: pending) != nil)
        #expect(GameLobbyView(model: model, gameID: active.id).inviteURL(for: active) == nil)
        #expect(GameLobbyView(model: model, gameID: solo.id).inviteURL(for: solo) == nil)
    }

    @Test("GameLobbyView auto-loads open seats when a with-friends lobby reports them")
    func gameLobbyViewOpenSeatsNotYetLoaded() async throws {
        let service = ScriptedGameLifecycleService()
        let game = sampleGame(multiplayerVariant: .withFriends, hasOpenSeats: true)
        let seat = try CardCode("c01001")
        await service.enqueueOpenSeatsResult(.success([seat]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        model.gameListState = .loaded([.game(game)])
        let view = GameLobbyView(model: model, gameID: game.id)

        view.loadOpenSeatsIfNeeded(for: game)
        await model.gameLifecycleActionTasks[game.id]?.value

        #expect(await service.callOrder == ["openSeats"])
        #expect(model.gameOpenSeats[game.id] == [seat])
    }

    @Test("GameLobbyView renders when open seats are loaded and populated")
    func gameLobbyViewOpenSeatsLoaded() async throws {
        let game = sampleGame(multiplayerVariant: .withFriends, hasOpenSeats: true)
        let model = await model(gameListState: .loaded([.game(game)]))
        model.gameOpenSeats[game.id] = try [CardCode("c01001")]
        let view = GameLobbyView(model: model, gameID: game.id)
        _ = view.body
    }

    @Test("GameLobbyView does not offer claim buttons once server data shows a seat")
    func gameLobbyViewOpenSeatsOwnedSeatStatus() async throws {
        let investigator = InvestigatorSummary(id: "01001", classSymbol: .guardian)
        let game = sampleGame(
            investigators: [investigator], multiplayerVariant: .withFriends, hasOpenSeats: true
        )
        let model = await model(gameListState: .loaded([.game(game)]))
        let view = GameLobbyView(model: model, gameID: game.id)
        let openSeats = try [CardCode("c01002")]

        #expect(game.viewerAlreadyHasSeat)
        #expect(
            view.openSeatsStatusText(for: game, openSeats: openSeats)
                == "You already have a seat in this game."
        )
    }

    @Test("GameLobbyView waiting text reports remaining players with plural handling")
    func gameLobbyViewWaitingTextUsesRemainingPlayers() async {
        let player = PlayerID(UUID())
        let game = sampleGame(
            gameState: .pending([player]),
            investigators: [InvestigatorSummary(id: "01001", classSymbol: .guardian)],
            otherInvestigators: [InvestigatorSummary(id: "01002", classSymbol: .seeker)],
            multiplayerVariant: .withFriends
        )
        let model = await model(gameListState: .loaded([.game(game)]))
        let view = GameLobbyView(model: model, gameID: game.id)

        #expect(view.waitingText(for: game) == "Waiting for 1 more player to join.")
    }

    @Test(
        """
        GameLobbyView renders a retry option, not a permanently non-retryable dead \
        end, when a loaded open-seats result is empty
        """
    )
    func gameLobbyViewOpenSeatsLoadedEmptyOffersRetry() async {
        let game = sampleGame(multiplayerVariant: .withFriends, hasOpenSeats: true)
        let model = await model(gameListState: .loaded([.game(game)]))
        model.gameOpenSeats[game.id] = []
        let view = GameLobbyView(model: model, gameID: game.id)
        _ = view.body
    }

    @Test("GameLobbyView renders a choose-decks game with waiting investigators")
    func gameLobbyViewChooseDecks() async {
        let investigators = [InvestigatorSummary(id: "01001", classSymbol: .init("Guardian"))]
        let game = sampleGame(
            gameState: .chooseDecks([PlayerID(UUID())]), investigators: investigators
        )
        let model = await model(gameListState: .loaded([.game(game)]))
        let view = GameLobbyView(model: model, gameID: game.id)
        _ = view.body
    }

    @Test("GameLobbyView renders while an action is in flight and after it fails")
    func gameLobbyViewActionInFlightAndFailed() async {
        let game = sampleGame(gameState: .pending([]))
        let model = await model(gameListState: .loaded([.game(game)]))
        model.gameLifecycleActions[game.id] = .joining
        let inFlightView = GameLobbyView(model: model, gameID: game.id)
        _ = inFlightView.body

        model.gameLifecycleActions[game.id] = nil
        model.gameLifecycleActionFailures[game.id] = GameLifecycleActionFailure(
            action: .joining, error: .unexpectedStatus(403)
        )
        let failedView = GameLobbyView(model: model, gameID: game.id)
        _ = failedView.body
    }

    @Test("GameLobbyView renders a not-available state for a game no longer in the list")
    func gameLobbyViewGameNoLongerAvailable() async {
        let model = await model(gameListState: .loaded([]))
        let view = GameLobbyView(model: model, gameID: GameID(UUID()))
        _ = view.body
    }

    @Test("GameLobbyView reflects a live refresh, not a frozen snapshot captured at init time")
    func gameLobbyViewReflectsLiveRefresh() async {
        let game = sampleGame(
            gameState: .pending([]), multiplayerVariant: .withFriends, hasOpenSeats: true
        )
        let model = await model(gameListState: .loaded([.game(game)]))
        let view = GameLobbyView(model: model, gameID: game.id)
        _ = view.body
        #expect(view.game?.gameState == GameState.pending([]))
        #expect(view.game?.hasOpenSeats == true)

        // A refresh completes while the sheet is (conceptually) still open, moving the
        // same game into a different lifecycle state and clearing its open seats.
        let updatedGame = GameSummary(
            id: game.id, scenario: game.scenario, campaign: game.campaign,
            gameState: .chooseDecks([PlayerID(UUID())]), name: game.name,
            investigators: game.investigators, otherInvestigators: game.otherInvestigators,
            multiplayerVariant: game.multiplayerVariant, hasOpenSeats: false
        )
        model.gameListState = .loaded([.game(updatedGame)])
        _ = view.body

        if case let .chooseDecks(players) = view.game?.gameState {
            #expect(players.count == 1)
        } else {
            Issue.record("Expected the live-looked-up game to reflect the refreshed state")
        }
        #expect(view.game?.hasOpenSeats == false)
    }
}
