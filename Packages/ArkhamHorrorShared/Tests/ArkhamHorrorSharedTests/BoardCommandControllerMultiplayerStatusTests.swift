@testable import ArkhamHorrorShared
import Testing

@MainActor
@Suite("BoardCommandController — multiplayer status wiring")
struct BoardControllerStatusTests {
    @Test("Spectator flag feeds controller multiplayer status from init and updates")
    func spectatorFlagFeedsMultiplayerStatusFromInitAndUpdates() {
        let projection = multiplayerProjectionWithPendingPrompt()

        let spectatorController = BoardCommandController(
            projection: projection,
            isLocalSpectator: true
        )
        #expect(spectatorController.multiplayerStatus.isLocalSpectator)
        #expect(
            spectatorController.multiplayerStatus.localPromptText
                == "Spectating. Waiting for Daisy Walker."
        )

        let updatingController = BoardCommandController(
            projection: projection,
            isLocalSpectator: false
        )
        #expect(!updatingController.multiplayerStatus.isLocalSpectator)
        #expect(
            updatingController.multiplayerStatus.localPromptText == "Waiting for player identity."
        )

        updatingController.updateIsLocalSpectator(true)

        #expect(updatingController.multiplayerStatus.isLocalSpectator)
        #expect(
            updatingController.multiplayerStatus.localPromptText
                == "Spectating. Waiting for Daisy Walker."
        )
    }

    private func multiplayerProjectionWithPendingPrompt() -> BoardProjection {
        let waitingInvestigatorID = BoardTestFixtures.investigatorID("c01001")
        let promptInvestigatorID = BoardTestFixtures.investigatorID("c01002")
        let waitingPlayerID = BoardTestFixtures.playerID("000000000811")
        let promptPlayerID = BoardTestFixtures.playerID("000000000812")
        let snapshot = BoardTestFixtures.snapshot(
            investigators: [
                waitingInvestigatorID: BoardTestFixtures.investigator(
                    id: waitingInvestigatorID,
                    name: CardName(title: "Roland Banks", subtitle: nil),
                    playerID: waitingPlayerID
                ),
                promptInvestigatorID: BoardTestFixtures.investigator(
                    id: promptInvestigatorID,
                    name: CardName(title: "Daisy Walker", subtitle: nil),
                    playerID: promptPlayerID
                ),
            ],
            playerOrder: [waitingInvestigatorID, promptInvestigatorID],
            activeInvestigatorID: promptInvestigatorID,
            turnPlayerInvestigatorID: promptInvestigatorID,
            leadInvestigatorID: waitingInvestigatorID,
            questionPlayerIDs: [promptPlayerID],
            playerCount: 2
        )
        return BoardProjectionBuilder.makeProjection(from: snapshot)
    }
}
