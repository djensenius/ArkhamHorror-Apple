@testable import ArkhamHorrorShared
import Testing

@Suite("Board linked enemy action reciprocity")
struct BoardLinkedEnemyActionReciprocityTests {
    @Test("Nonreciprocal fallback enemy action edges use self edges")
    func nonreciprocalFallbackEnemyActionEdgesUseSelfEdges() {
        let rootID = BoardTestFixtures.locationID("000000000490")
        let actionLocationID = BoardTestFixtures.locationID("000000000491")
        let siblingLocationID = BoardTestFixtures.locationID("000000000492")
        let enemyID = BoardTestFixtures.enemyID("000000000493")
        let projection = locationEnemyProjection(
            rootID: rootID,
            actionLocationID: actionLocationID,
            siblingLocationID: siblingLocationID,
            enemyID: enemyID
        )
        let layout = BoardLayoutBuilder.makeLayout(
            locations: projection.locations,
            preferredRootID: rootID
        )
        let graph = BoardFocusGraphBuilder.makeGraph(
            projection: projection,
            layout: layout,
            prompt: enemyPrompt(choices: [fightChoice(index: 7, enemyID: enemyID)])
        )
        let rootFocus = BoardFocusID.location(rootID)
        let actionsFocus = BoardFocusID.locationEnemyActions(actionLocationID)
        let siblingFocus = BoardFocusID.location(siblingLocationID)

        #expect(graph.neighbor(from: actionsFocus, direction: .right) == actionsFocus)
        #expect(graph.neighbor(from: siblingFocus, direction: .left) == rootFocus)
        #expect(graph.neighbor(from: actionsFocus, direction: .down) == siblingFocus)
        #expect(graph.neighbor(from: siblingFocus, direction: .up) == actionsFocus)
    }

    private func locationEnemyProjection(
        rootID: LocationID,
        actionLocationID: LocationID,
        siblingLocationID: LocationID,
        enemyID: EnemyID
    ) -> BoardProjection {
        BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: [
                (rootID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: rootID,
                    connectedLocations: [actionLocationID, siblingLocationID]
                ))),
                (actionLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: actionLocationID,
                    connectedLocations: [rootID],
                    enemies: [enemyID]
                ))),
                (siblingLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: siblingLocationID,
                    connectedLocations: [rootID]
                ))),
            ],
            enemyValues: [enemyID: .null]
        ))
    }

    private func enemyPrompt(choices: [BasicChoice]) -> BasicChoicePromptPresentation {
        let rawQuestion: JSONValue = .object([
            "tag": .string(BasicChoiceQuestionKind.chooseOne.rawValue),
            "choices": .array(choices.map(\.rawValue)),
        ])
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: 1,
                rawQuestion: rawQuestion,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: .supported(BasicChoiceQuestion(
                kind: .chooseOne,
                choices: choices,
                story: nil,
                rawValue: rawQuestion
            )),
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private func fightChoice(index: Int, enemyID: EnemyID) -> BasicChoice {
        BasicChoice(
            index: index,
            rawValue: .string("fight-\(index)"),
            content: .fight(enemyAbility(), enemyID: enemyID)
        )
    }

    private func enemyAbility() -> BasicChoiceAbility {
        BasicChoiceAbility(
            investigatorID: BoardTestFixtures.investigatorID("c01001"),
            cardCode: BoardTestFixtures.cardCode("c01160"),
            rawAbility: .null,
            windows: [],
            before: [],
            messages: []
        )
    }
}
