@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Games list surface reconciliation")
struct GamesListSurfaceReconciliationTests {
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

    @Test("reconcileOpenGameSurfaces clears lobby sheet and live route after definite absence")
    func reconcileOpenGameSurfacesClosesAbsentGame() {
        let missingGameID = GameID(UUID())
        let remainingGameID = GameID(UUID())
        let games: GameList = [.game(sampleGame(id: remainingGameID))]
        var presentedGameID: GameID? = missingGameID
        var liveGamePath = [remainingGameID, missingGameID]

        OpenGameSurfaceReconciler.reconcile(
            presentedGameID: &presentedGameID,
            liveGamePath: &liveGamePath,
            gameListState: .loaded(games),
            confirmedDeletedGameIDs: []
        )

        #expect(presentedGameID == nil)
        #expect(liveGamePath == [remainingGameID])
    }

    @Test("reconcileOpenGameSurfaces keeps routes when absence is ambiguous")
    func reconcileOpenGameSurfacesKeepsAmbiguousMissingGame() {
        let missingGameID = GameID(UUID())
        let remainingGameID = GameID(UUID())
        let games: GameList = [
            .game(sampleGame(id: remainingGameID)),
            .failed(FailedGameEntry(error: "Could not decode a game.")),
        ]
        var presentedGameID: GameID? = missingGameID
        var liveGamePath = [missingGameID]

        OpenGameSurfaceReconciler.reconcile(
            presentedGameID: &presentedGameID,
            liveGamePath: &liveGamePath,
            gameListState: .loaded(games),
            confirmedDeletedGameIDs: []
        )

        #expect(presentedGameID == missingGameID)
        #expect(liveGamePath == [missingGameID])
    }

    @Test("reconcileOpenGameSurfaces closes confirmed deletes even with failed list entries")
    func reconcileOpenGameSurfacesClosesConfirmedDeleteWithFailedEntries() {
        let deletedGameID = GameID(UUID())
        let remainingGameID = GameID(UUID())
        let games: GameList = [
            .game(sampleGame(id: remainingGameID)),
            .failed(FailedGameEntry(error: "Could not decode a game.")),
        ]
        var presentedGameID: GameID? = deletedGameID
        var liveGamePath = [remainingGameID, deletedGameID]

        OpenGameSurfaceReconciler.reconcile(
            presentedGameID: &presentedGameID,
            liveGamePath: &liveGamePath,
            gameListState: .loaded(games),
            confirmedDeletedGameIDs: [deletedGameID]
        )

        #expect(presentedGameID == nil)
        #expect(liveGamePath == [remainingGameID])
    }

    @Test("confirmed deletes close lobby sheets and live routes while refresh is loading")
    func confirmedDeleteReconciliationClosesDuringLoadingPreviousList() {
        let deletedGameID = GameID(UUID())
        let remainingGameID = GameID(UUID())
        let previous: GameList = [.game(sampleGame(id: remainingGameID))]

        let result = OpenGameSurfaceReconciler.reconciled(
            presentedGameID: deletedGameID,
            liveGamePath: [remainingGameID, deletedGameID],
            gameListState: .loading(previous: previous),
            confirmedDeletedGameIDs: [deletedGameID]
        )

        #expect(result.presentedGameID == nil)
        #expect(result.liveGamePath == [remainingGameID])
    }

    @Test("confirmed deletes close lobby sheets and live routes after a failed refresh")
    func confirmedDeleteReconciliationClosesDuringFailedPreviousList() {
        let deletedGameID = GameID(UUID())
        let remainingGameID = GameID(UUID())
        let previous: GameList = [
            .game(sampleGame(id: remainingGameID)),
            .failed(FailedGameEntry(error: "Could not decode a game.")),
        ]

        let result = OpenGameSurfaceReconciler.reconciled(
            presentedGameID: deletedGameID,
            liveGamePath: [remainingGameID, deletedGameID],
            gameListState: .failed(.unexpectedStatus(500), previous: previous),
            confirmedDeletedGameIDs: [deletedGameID]
        )

        #expect(result.presentedGameID == nil)
        #expect(result.liveGamePath == [remainingGameID])
    }
}
