@testable import ArkhamHorrorShared
import Testing

@MainActor
@Suite("Board linked choice menu dismissal")
struct BoardLinkedChoiceMenuDismissalTests {
    @Test("Accessibility escape dispatch dismisses linked choice menu without submitting")
    func accessibilityEscapeDispatchDismissesLinkedChoiceMenu() {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let playerID = BoardTestFixtures.playerID("000000000001")
        let enemyID = BoardTestFixtures.enemyID("000000000486")
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    engagedEnemies: [enemyID],
                    playerID: playerID
                ),
            ],
            playerOrder: [investigatorID],
            activeInvestigatorID: investigatorID,
            enemyValues: [enemyID: .null]
        ))
        let prompt = enemyPrompt(choices: [
            enemyChoice(index: 7, enemyID: enemyID, kind: .fight),
            enemyChoice(index: 8, enemyID: enemyID, kind: .evade),
        ])
        var submittedChoices: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            localPlayerID: playerID,
            onChoice: { submittedChoices.append($0) }
        )
        let enemyFocus = BoardFocusID.promptElement(.enemy(enemyID))

        #expect(controller.handle(focusID: enemyFocus, .command(.primaryAction)))
        guard let request = controller.linkedChoiceMenuRequest else {
            Issue.record("Expected linked-choice menu request")
            return
        }
        let dispatch = BoardLinkedChoiceMenuCancelAction.dispatch(for: request)

        #expect(dispatch == BoardLinkedChoiceMenuCancelDispatch(
            focusID: enemyFocus,
            outcome: .reservedBack
        ))
        #expect(controller.handle(focusID: dispatch.focusID, dispatch.outcome))
        #expect(controller.linkedChoiceMenuRequest == nil)
        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.coordinator.currentFocus == enemyFocus)
        #expect(submittedChoices.isEmpty)
    }

    private enum EnemyChoiceKind {
        case fight
        case evade
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

    private func enemyChoice(
        index: Int,
        enemyID: EnemyID,
        kind: EnemyChoiceKind
    ) -> BasicChoice {
        let ability = BasicChoiceAbility(
            investigatorID: BoardTestFixtures.investigatorID("c01001"),
            cardCode: BoardTestFixtures.cardCode("c01160"),
            rawAbility: .null,
            windows: [],
            before: [],
            messages: []
        )
        switch kind {
        case .fight:
            return BasicChoice(
                index: index,
                rawValue: .string("fight-\(index)"),
                content: .fight(ability, enemyID: enemyID)
            )
        case .evade:
            return BasicChoice(
                index: index,
                rawValue: .string("evade-\(index)"),
                content: .evade(ability, enemyID: enemyID)
            )
        }
    }
}
