@testable import ArkhamHorrorShared
import Testing

@MainActor
@Suite("Board linked element focus and prompt actions")
struct BoardLinkedElementFocusTests {
    private func enemyProjection(
        investigatorID: InvestigatorID,
        playerID: PlayerID,
        enemyIDs: [EnemyID]
    ) -> BoardProjection {
        BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    engagedEnemies: enemyIDs,
                    playerID: playerID
                ),
            ],
            playerOrder: [investigatorID],
            activeInvestigatorID: investigatorID,
            enemyValues: Dictionary(uniqueKeysWithValues: enemyIDs.map { ($0, JSONValue.null) })
        ))
    }

    private func locationEnemyProjection(
        locations: [(LocationID, Location)],
        enemyIDs: [EnemyID]
    ) -> BoardProjection {
        BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: locations,
            enemyValues: Dictionary(uniqueKeysWithValues: enemyIDs.map { ($0, JSONValue.null) })
        ))
    }

    private func enemyPrompt(
        choices: [BasicChoice],
        ownerID: PlayerID = BoardTestFixtures.playerID("000000000001"),
        readOnlyReason: BasicChoiceReadOnlyReason? = nil
    ) -> BasicChoicePromptPresentation {
        let rawQuestion: JSONValue = .object([
            "tag": .string(BasicChoiceQuestionKind.chooseOne.rawValue),
            "choices": .array(choices.map(\.rawValue)),
        ])
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: ownerID,
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
            readOnlyReason: readOnlyReason,
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

    private func evadeChoice(index: Int, enemyID: EnemyID) -> BasicChoice {
        BasicChoice(
            index: index,
            rawValue: .string("evade-\(index)"),
            content: .evade(enemyAbility(), enemyID: enemyID)
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

    @Test("Linked board enemies become concrete focus nodes in screen order")
    func linkedEnemyFocusNodesFollowInvestigatorScreenOrder() {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let playerID = BoardTestFixtures.playerID("000000000001")
        let firstEnemyID = BoardTestFixtures.enemyID("000000000411")
        let secondEnemyID = BoardTestFixtures.enemyID("000000000412")
        let unlinkedEnemyID = BoardTestFixtures.enemyID("000000000413")
        let projection = enemyProjection(
            investigatorID: investigatorID,
            playerID: playerID,
            enemyIDs: [firstEnemyID, secondEnemyID, unlinkedEnemyID]
        )
        let prompt = enemyPrompt(
            choices: [
                fightChoice(index: 7, enemyID: firstEnemyID),
                evadeChoice(index: 8, enemyID: secondEnemyID),
            ],
            ownerID: playerID
        )
        let graph = BoardFocusGraphBuilder.makeGraph(
            projection: projection,
            layout: BoardLayoutBuilder.makeLayout(locations: []),
            prompt: prompt,
            fullPlayerAreaPlayerID: playerID
        )
        let investigatorFocus = BoardFocusID.investigator(investigatorID)
        let firstEnemyFocus = BoardFocusID.promptElement(.enemy(firstEnemyID))
        let secondEnemyFocus = BoardFocusID.promptElement(.enemy(secondEnemyID))
        let unlinkedEnemyFocus = BoardFocusID.promptElement(.enemy(unlinkedEnemyID))

        #expect(graph.node(for: firstEnemyFocus)?.zone == BoardFocusZone.investigators)
        #expect(graph.node(for: secondEnemyFocus)?.zone == BoardFocusZone.investigators)
        #expect(!graph.contains(unlinkedEnemyFocus))
        #expect(graph.neighbor(from: investigatorFocus, direction: .right) == firstEnemyFocus)
        #expect(graph.neighbor(from: firstEnemyFocus, direction: .right) == secondEnemyFocus)
        let investigatorOrder = graph.order.filter {
            graph.node(for: $0)?.zone == BoardFocusZone.investigators
        }
        #expect(investigatorOrder == [
            investigatorFocus,
            firstEnemyFocus,
            secondEnemyFocus,
        ])
    }

    @Test("Primary action on a focused linked enemy submits its single server choice index")
    func primaryActionOnSingleLinkedEnemySubmitsChoiceIndex() {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let playerID = BoardTestFixtures.playerID("000000000001")
        let enemyID = BoardTestFixtures.enemyID("000000000421")
        let projection = enemyProjection(
            investigatorID: investigatorID,
            playerID: playerID,
            enemyIDs: [enemyID]
        )
        let prompt = enemyPrompt(
            choices: [fightChoice(index: 7, enemyID: enemyID)],
            ownerID: playerID
        )
        var submittedChoices: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            localPlayerID: playerID,
            onChoice: { submittedChoices.append($0) }
        )

        #expect(controller.handle(
            focusID: BoardFocusID.promptElement(.enemy(enemyID)),
            .command(.primaryAction)
        ))
        #expect(submittedChoices == [7])
    }

    @Test("Primary action on a multi-choice linked enemy requests the choice menu")
    func primaryActionOnMultiLinkedEnemyRequestsMenuWithoutSubmittingOrInspecting() {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let playerID = BoardTestFixtures.playerID("000000000001")
        let enemyID = BoardTestFixtures.enemyID("000000000431")
        let projection = enemyProjection(
            investigatorID: investigatorID,
            playerID: playerID,
            enemyIDs: [enemyID]
        )
        let prompt = enemyPrompt(
            choices: [
                fightChoice(index: 7, enemyID: enemyID),
                evadeChoice(index: 8, enemyID: enemyID),
            ],
            ownerID: playerID
        )
        var submittedChoices: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            localPlayerID: playerID,
            onChoice: { submittedChoices.append($0) }
        )

        #expect(controller.handle(
            focusID: BoardFocusID.promptElement(.enemy(enemyID)),
            .command(.primaryAction)
        ))
        #expect(controller.linkedChoiceMenuRequest == BoardLinkedChoiceMenuRequest(
            focusID: BoardFocusID.promptElement(.enemy(enemyID)),
            choices: [
                BoardLinkedChoice(choiceIndex: 7, title: "Fight", isActionable: true),
                BoardLinkedChoice(choiceIndex: 8, title: "Evade", isActionable: true),
            ]
        ))
        #expect(controller.coordinator.isModalPresented)
        #expect(controller.coordinator.currentFocus == BoardFocusID.linkedChoiceMenuChoice(7))
        #expect(controller.coordinator.graph.contains(BoardFocusID.linkedChoiceMenuChoice(8)))
        #expect(submittedChoices.isEmpty)
        #expect(controller.inspectedID == nil)

        #expect(controller.handle(
            focusID: BoardFocusID.linkedChoiceMenuChoice(8),
            .command(.primaryAction)
        ))
        #expect(submittedChoices == [8])
        #expect(controller.linkedChoiceMenuRequest == nil)
        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptElement(.enemy(enemyID)))
    }

    @Test("Back and secondary dismiss a controller-opened linked choice menu")
    func linkedChoiceMenuDismissesWithBackAndSecondary() {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let playerID = BoardTestFixtures.playerID("000000000001")
        let enemyID = BoardTestFixtures.enemyID("000000000432")
        let projection = enemyProjection(
            investigatorID: investigatorID,
            playerID: playerID,
            enemyIDs: [enemyID]
        )
        let prompt = enemyPrompt(
            choices: [
                fightChoice(index: 7, enemyID: enemyID),
                evadeChoice(index: 8, enemyID: enemyID),
            ],
            ownerID: playerID
        )
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            localPlayerID: playerID
        )
        let enemyFocus = BoardFocusID.promptElement(.enemy(enemyID))

        #expect(controller.handle(focusID: enemyFocus, .command(.primaryAction)))
        #expect(controller.handle(.reservedBack))
        #expect(controller.linkedChoiceMenuRequest == nil)
        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.coordinator.currentFocus == enemyFocus)
        #expect(!controller.coordinator.graph.contains(BoardFocusID.linkedChoiceMenuChoice(7)))

        #expect(controller.handle(focusID: enemyFocus, .command(.primaryAction)))
        #expect(controller.handle(.command(.secondaryAction)))
        #expect(controller.linkedChoiceMenuRequest == nil)
        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.coordinator.currentFocus == enemyFocus)
    }
}
