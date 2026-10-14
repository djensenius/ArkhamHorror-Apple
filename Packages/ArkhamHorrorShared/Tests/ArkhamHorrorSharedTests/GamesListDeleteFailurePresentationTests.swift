@testable import ArkhamHorrorShared
import Foundation
import SwiftUI
import Testing

@MainActor
@Suite("Games list delete failure presentation")
struct GamesListDeleteFailurePresentationTests {
    private func sampleGame(id: GameID = GameID(UUID())) -> GameSummary {
        GameSummary(
            id: id,
            scenario: nil,
            campaign: nil,
            gameState: .active,
            name: "Sample",
            investigators: [],
            otherInvestigators: [],
            multiplayerVariant: .solo,
            hasOpenSeats: false
        )
    }

    private func model(gameListState: GameListLoadState) async -> AppModel {
        let service = ScriptedGameLifecycleService()
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        model.gameListState = gameListState
        return model
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

    @Test("Failed rows with IDs render the same row-local delete failure presentation")
    func failedRowDeleteFailurePresentationUsesServerMessage() async throws {
        let gameID = GameID(UUID())
        let failedEntry = FailedGameEntry(
            id: gameID,
            name: "Broken contract fixture",
            error: "Contract fixture failed to load."
        )
        let serverMessage = "Delete is disabled while this game is being updated."
        let model = await model(gameListState: .loaded([.failed(failedEntry)]))
        model.gameLifecycleActionFailures[gameID] = GameLifecycleActionFailure(
            action: .deleting,
            error: .operationFailed(DeckOperationError(errorMsg: serverMessage))
        )
        let view = GamesListView(model: model)

        let presentation = try #require(view.deleteFailurePresentation(for: failedEntry))
        #expect(presentation.message == serverMessage)
        #expect(
            presentation.accessibilityIdentifier
                == AccountAccessibilityID.gameActionFailureText(for: gameID.rawValue)
        )
        _ = view.row(for: .failed(failedEntry))
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
