@testable import ArkhamHorrorShared
import Testing

@Suite("Board player area visibility")
struct BoardPlayerAreaVisibilityTests {
    private let playerID = BoardTestFixtures.playerID("000000000801")

    @Test("Full player area selection prefers prompt owner, local player, then active investigator")
    // Covers the controller priority and the row-level visibility decision together.
    // swiftlint:disable:next function_body_length
    func fullPlayerAreaSelectionOrder() throws {
        let activeID = BoardTestFixtures.investigatorID("c01001")
        let localID = BoardTestFixtures.investigatorID("c01002")
        let promptID = BoardTestFixtures.investigatorID("c01003")
        let localPlayerID = BoardTestFixtures.playerID("000000000802")
        let promptPlayerID = BoardTestFixtures.playerID("000000000803")
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: [
                activeID: BoardTestFixtures.investigator(id: activeID, playerID: playerID),
                localID: BoardTestFixtures.investigator(id: localID, playerID: localPlayerID),
                promptID: BoardTestFixtures.investigator(id: promptID, playerID: promptPlayerID),
            ],
            playerOrder: [activeID, localID, promptID],
            activeInvestigatorID: activeID
        ))
        let active = try #require(projection.investigators.first { $0.id == activeID })
        let local = try #require(projection.investigators.first { $0.id == localID })
        let prompt = try #require(projection.investigators.first { $0.id == promptID })

        #expect(BoardCommandController.fullPlayerAreaPlayerID(
            promptOwnerID: promptPlayerID,
            localPlayerID: localPlayerID,
            activeInvestigatorPlayerID: playerID
        ) == promptPlayerID)
        #expect(BoardCommandController.fullPlayerAreaPlayerID(
            promptOwnerID: nil,
            localPlayerID: localPlayerID,
            activeInvestigatorPlayerID: playerID
        ) == localPlayerID)
        #expect(BoardCommandController.fullPlayerAreaPlayerID(
            promptOwnerID: nil,
            localPlayerID: nil,
            activeInvestigatorPlayerID: playerID
        ) == playerID)
        #expect(BoardPlayerAreaVisibility.shouldShowFullArea(
            for: prompt,
            fullPlayerAreaPlayerID: promptPlayerID
        ))
        #expect(!BoardPlayerAreaVisibility.shouldShowFullArea(
            for: local,
            fullPlayerAreaPlayerID: promptPlayerID
        ))
        #expect(BoardPlayerAreaVisibility.shouldShowFullArea(
            for: local,
            fullPlayerAreaPlayerID: localPlayerID
        ))
        #expect(BoardPlayerAreaVisibility.shouldShowFullArea(
            for: active,
            fullPlayerAreaPlayerID: nil
        ))
        #expect(!BoardPlayerAreaVisibility.shouldShowFullArea(
            for: local,
            fullPlayerAreaPlayerID: nil
        ))

        #expect(BoardCommandController.fullPlayerAreaPlayerID(
            promptOwnerID: promptPlayerID,
            localPlayerID: localPlayerID,
            activeInvestigatorPlayerID: playerID,
            isSolo: false
        ) == localPlayerID)
        #expect(BoardCommandController.fullPlayerAreaPlayerID(
            promptOwnerID: promptPlayerID,
            localPlayerID: nil,
            activeInvestigatorPlayerID: playerID,
            isSolo: false
        ) == nil)
        #expect(!BoardPlayerAreaVisibility.shouldShowFullArea(
            for: prompt,
            fullPlayerAreaPlayerID: localPlayerID,
            isSolo: false
        ))
        #expect(!BoardPlayerAreaVisibility.shouldShowFullArea(
            for: active,
            fullPlayerAreaPlayerID: nil,
            isSolo: false
        ))
    }
}
