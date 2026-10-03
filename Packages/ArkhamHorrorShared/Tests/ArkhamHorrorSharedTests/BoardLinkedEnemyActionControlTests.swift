@testable import ArkhamHorrorShared
import Testing

@MainActor
@Suite("Board linked enemy action controls")
struct BoardLinkedEnemyActionControlTests {
    private struct DuplicateEnemyLocationIDs {
        let location: LocationID
        let firstEnemy: EnemyID
        let secondEnemy: EnemyID
    }

    private func locationEnemyProjection(
        locations: [(LocationID, Location)],
        enemyIDs: [EnemyID],
        enemyValues: [EnemyID: JSONValue] = [:]
    ) -> BoardProjection {
        BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: locations,
            enemyValues: Dictionary(uniqueKeysWithValues: enemyIDs.map {
                ($0, enemyValues[$0] ?? JSONValue.null)
            })
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

    private func enemyValue(
        name: String,
        fight: Int = 2,
        health: Int = 2,
        evade: Int = 3
    ) -> JSONValue {
        var value = enemyValueWithoutInlineName(fight: fight, health: health, evade: evade)
        value["name"] = .object(["title": .string(name)])
        return .object(value)
    }

    private func enemyValueWithoutInlineName(
        cardCode: String = "c01159",
        fight: Int = 2,
        health: Int = 2,
        evade: Int = 3
    ) -> [String: JSONValue] {
        [
            "cardCode": .string(cardCode),
            "fight": .number(.integer(Int64(fight))),
            "health": .number(.integer(Int64(health))),
            "evade": .number(.integer(Int64(evade))),
        ]
    }

    @Test("Location enemy action menu titles identify duplicate enemy names")
    func locationEnemyActionMenuTitlesIdentifyDuplicateEnemyNames() {
        let ids = duplicateEnemyLocationIDs()
        let projection = locationEnemyProjection(
            locations: [(
                ids.location,
                .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: ids.location,
                    enemies: [ids.firstEnemy, ids.secondEnemy]
                ))
            )],
            enemyIDs: [ids.firstEnemy, ids.secondEnemy],
            enemyValues: [
                ids.firstEnemy: enemyValue(name: "Ghoul Minion"),
                ids.secondEnemy: enemyValue(name: "Ghoul Minion"),
            ]
        )
        let prompt = enemyPrompt(choices: duplicateEnemyChoices(ids))
        let actionsFocus = BoardFocusID.locationEnemyActions(ids.location)
        let controller = BoardCommandController(projection: projection, prompt: prompt)

        #expect(controller.handle(focusID: actionsFocus, .command(.primaryAction)))
        #expect(controller.linkedChoiceMenuRequest == BoardLinkedChoiceMenuRequest(
            focusID: actionsFocus,
            choices: expectedDuplicateEnemyMenuChoices()
        ))
    }

    @Test("Location enemy action menu titles use catalog names when payload omits names")
    func locationEnemyActionMenuTitlesUseCatalogNamesWhenPayloadOmitsNames() {
        let ids = duplicateEnemyLocationIDs()
        let projection = locationEnemyProjection(
            locations: [(
                ids.location,
                .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: ids.location,
                    enemies: [ids.firstEnemy, ids.secondEnemy]
                ))
            )],
            enemyIDs: [ids.firstEnemy, ids.secondEnemy],
            enemyValues: [
                ids.firstEnemy: .object(enemyValueWithoutInlineName(cardCode: "c01159")),
                ids.secondEnemy: .object(enemyValueWithoutInlineName(cardCode: "c01159")),
            ]
        )
        let prompt = enemyPrompt(choices: duplicateEnemyChoices(ids))
        let actionsFocus = BoardFocusID.locationEnemyActions(ids.location)
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            cardCatalog: CardCatalogSnapshot(namesByCode: [
                BoardTestFixtures.cardCode("c01159"): CardName(title: "Ghoul Minion", subtitle: nil),
            ])
        )

        #expect(controller.handle(focusID: actionsFocus, .command(.primaryAction)))
        #expect(controller.linkedChoiceMenuRequest == BoardLinkedChoiceMenuRequest(
            focusID: actionsFocus,
            choices: expectedDuplicateEnemyMenuChoices()
        ))
    }

    @Test("Single-choice location enemy action control submits directly")
    func singleChoiceLocationEnemyActionControlSubmitsDirectly() {
        let locationID = BoardTestFixtures.locationID("000000000456")
        let enemyID = BoardTestFixtures.enemyID("000000000457")
        let projection = locationEnemyProjection(
            locations: [(
                locationID,
                .ordinary(BoardTestFixtures.ordinaryLocation(id: locationID, enemies: [enemyID]))
            )],
            enemyIDs: [enemyID],
            enemyValues: [enemyID: enemyValue(name: "Ghoul Minion")]
        )
        let prompt = enemyPrompt(choices: [fightChoice(index: 7, enemyID: enemyID)])
        let actionsFocus = BoardFocusID.locationEnemyActions(locationID)
        var submittedChoices: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onChoice: { submittedChoices.append($0) }
        )

        #expect(controller.coordinator.graph.contains(actionsFocus))
        #expect(controller.handle(focusID: actionsFocus, .command(.primaryAction)))
        #expect(submittedChoices == [7])
        #expect(controller.linkedChoiceMenuRequest == nil)
        #expect(!controller.coordinator.isModalPresented)
    }

    @Test("Highlight-only location enemy choices do not create an action control")
    func highlightOnlyLocationEnemyChoicesDoNotCreateActionControl() {
        let playerID = BoardTestFixtures.playerID("000000000458")
        let locationID = BoardTestFixtures.locationID("000000000459")
        let enemyID = BoardTestFixtures.enemyID("000000000460")
        let projection = locationEnemyProjection(
            locations: [(
                locationID,
                .ordinary(BoardTestFixtures.ordinaryLocation(id: locationID, enemies: [enemyID]))
            )],
            enemyIDs: [enemyID]
        )
        let prompt = enemyPrompt(
            choices: [fightChoice(index: 7, enemyID: enemyID)],
            ownerID: playerID,
            readOnlyReason: .anotherPlayer
        )
        let graph = BoardFocusGraphBuilder.makeGraph(
            projection: projection,
            layout: BoardLayoutBuilder.makeLayout(locations: projection.locations),
            prompt: prompt
        )
        let actionsFocus = BoardFocusID.locationEnemyActions(locationID)
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            localPlayerID: playerID
        )

        #expect(!graph.contains(actionsFocus))
        #expect(!controller.coordinator.graph.contains(actionsFocus))
        #expect(!controller.handle(focusID: actionsFocus, .command(.primaryAction)))
    }

    private func duplicateEnemyLocationIDs() -> DuplicateEnemyLocationIDs {
        DuplicateEnemyLocationIDs(
            location: BoardTestFixtures.locationID("000000000446"),
            firstEnemy: BoardTestFixtures.enemyID("000000000447"),
            secondEnemy: BoardTestFixtures.enemyID("000000000448")
        )
    }

    private func duplicateEnemyChoices(
        _ ids: DuplicateEnemyLocationIDs
    ) -> [BasicChoice] {
        [
            fightChoice(index: 7, enemyID: ids.firstEnemy),
            evadeChoice(index: 8, enemyID: ids.firstEnemy),
            fightChoice(index: 20, enemyID: ids.secondEnemy),
            evadeChoice(index: 21, enemyID: ids.secondEnemy),
        ]
    }

    private func expectedDuplicateEnemyMenuChoices() -> [BoardLinkedChoice] {
        [
            BoardLinkedChoice(
                choiceIndex: 7,
                title: "Ghoul Minion: F 2  H 2  E 3 (enemy 1): Fight",
                isActionable: true
            ),
            BoardLinkedChoice(
                choiceIndex: 8,
                title: "Ghoul Minion: F 2  H 2  E 3 (enemy 1): Evade",
                isActionable: true
            ),
            BoardLinkedChoice(
                choiceIndex: 20,
                title: "Ghoul Minion: F 2  H 2  E 3 (enemy 2): Fight",
                isActionable: true
            ),
            BoardLinkedChoice(
                choiceIndex: 21,
                title: "Ghoul Minion: F 2  H 2  E 3 (enemy 2): Evade",
                isActionable: true
            ),
        ]
    }
}
