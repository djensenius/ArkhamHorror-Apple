@testable import ArkhamHorrorShared
import Testing

@MainActor
@Suite("Board linked enemy action boundary focus")
struct BoardLinkedEnemyActionBoundaryFocusTests {
    @Test("Boundary enemy action edges never wrap into non-reciprocal location trips")
    func boundaryEnemyActionEdgesStayReciprocal() {
        let firstLocationID = BoardTestFixtures.locationID("000000000490")
        let secondLocationID = BoardTestFixtures.locationID("000000000491")
        let enemyID = BoardTestFixtures.enemyID("000000000492")
        let projection = makeProjection(
            firstLocationID: firstLocationID,
            secondLocationID: secondLocationID,
            enemyID: enemyID
        )
        let layout = BoardLayoutBuilder.makeLayout(
            locations: projection.locations,
            preferredRootID: firstLocationID
        )
        let graph = BoardFocusGraphBuilder.makeGraph(
            projection: projection,
            layout: layout,
            prompt: enemyPrompt(choice: fightChoice(index: 7, enemyID: enemyID))
        )
        let firstLocationFocus = BoardFocusID.location(firstLocationID)
        let secondLocationFocus = BoardFocusID.location(secondLocationID)
        let actionsFocus = BoardFocusID.locationEnemyActions(firstLocationID)

        #expect(layout.neighbors[firstLocationID]?[.right] == secondLocationID)
        #expect(graph.neighbor(from: actionsFocus, direction: .left) == actionsFocus)
        #expect(graph.neighbor(from: actionsFocus, direction: .down) == actionsFocus)
        #expect(graph.neighbor(from: actionsFocus, direction: .up) == firstLocationFocus)
        #expect(graph.neighbor(from: firstLocationFocus, direction: .down) == actionsFocus)
        #expect(graph.neighbor(from: actionsFocus, direction: .right) == secondLocationFocus)
        #expect(graph.neighbor(from: secondLocationFocus, direction: .left) == actionsFocus)
    }

    private func makeProjection(
        firstLocationID: LocationID,
        secondLocationID: LocationID,
        enemyID: EnemyID
    ) -> BoardProjection {
        BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: [
                (firstLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: firstLocationID,
                    connectedLocations: [secondLocationID],
                    enemies: [enemyID]
                ))),
                (secondLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: secondLocationID,
                    connectedLocations: [firstLocationID]
                ))),
            ],
            enemyValues: [enemyID: .null]
        ))
    }

    private func enemyPrompt(choice: BasicChoice) -> BasicChoicePromptPresentation {
        let rawQuestion: JSONValue = .object([
            "tag": .string(BasicChoiceQuestionKind.chooseOne.rawValue),
            "choices": .array([choice.rawValue]),
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
                choices: [choice],
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
