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

    @Test("Location enemies chain through a location before the location's original down neighbor")
    func locationEnemiesAreReachableBeforeOriginalDownNeighbor() {
        let rootID = BoardTestFixtures.locationID("000000000441")
        let locationID = BoardTestFixtures.locationID("000000000442")
        let downLocationID = BoardTestFixtures.locationID("000000000443")
        let firstEnemyID = BoardTestFixtures.enemyID("000000000444")
        let secondEnemyID = BoardTestFixtures.enemyID("000000000445")
        let projection = locationEnemyProjection(
            locations: [
                (rootID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: rootID,
                    connectedLocations: [locationID, downLocationID]
                ))),
                (locationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: locationID,
                    connectedLocations: [rootID, downLocationID],
                    enemies: [firstEnemyID, secondEnemyID]
                ))),
                (downLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: downLocationID,
                    connectedLocations: [rootID, locationID]
                ))),
            ],
            enemyIDs: [firstEnemyID, secondEnemyID]
        )
        let layout = BoardLayoutBuilder.makeLayout(
            locations: projection.locations,
            preferredRootID: rootID
        )
        let prompt = enemyPrompt(choices: [
            fightChoice(index: 7, enemyID: firstEnemyID),
            evadeChoice(index: 8, enemyID: secondEnemyID),
        ])
        let graph = BoardFocusGraphBuilder.makeGraph(
            projection: projection,
            layout: layout,
            prompt: prompt
        )
        let locationFocus = BoardFocusID.location(locationID)
        let downLocationFocus = BoardFocusID.location(downLocationID)
        let firstEnemyFocus = BoardFocusID.promptElement(.enemy(firstEnemyID))
        let secondEnemyFocus = BoardFocusID.promptElement(.enemy(secondEnemyID))

        #expect(layout.neighbors[locationID]?[.down] == downLocationID)
        #expect(graph.neighbor(from: locationFocus, direction: .down) == firstEnemyFocus)
        #expect(graph.neighbor(from: firstEnemyFocus, direction: .up) == locationFocus)
        #expect(graph.neighbor(from: firstEnemyFocus, direction: .down) == secondEnemyFocus)
        #expect(graph.neighbor(from: secondEnemyFocus, direction: .up) == firstEnemyFocus)
        #expect(graph.neighbor(from: secondEnemyFocus, direction: .down) == downLocationFocus)
    }

    @Test("Enemy-location focus nodes match the rendered compact enemy count")
    func enemyLocationFocusExcludesOverflowEnemies() {
        let enemyLocationID = BoardTestFixtures.locationID("000000000451")
        let enemyIDs = [
            BoardTestFixtures.enemyID("000000000452"),
            BoardTestFixtures.enemyID("000000000453"),
            BoardTestFixtures.enemyID("000000000454"),
            BoardTestFixtures.enemyID("000000000455"),
        ]
        let projection = locationEnemyProjection(
            locations: [(
                enemyLocationID,
                .enemy(BoardTestFixtures.enemyLocation(id: enemyLocationID, enemies: enemyIDs))
            )],
            enemyIDs: enemyIDs
        )
        let prompt = enemyPrompt(choices: enemyIDs.enumerated().map { offset, enemyID in
            fightChoice(index: 20 + offset, enemyID: enemyID)
        })
        let graph = BoardFocusGraphBuilder.makeGraph(
            projection: projection,
            layout: BoardLayoutBuilder.makeLayout(locations: projection.locations),
            prompt: prompt
        )
        let locationFocus = BoardFocusID.enemyLocation(enemyLocationID)
        let firstEnemyFocus = BoardFocusID.promptElement(.enemy(enemyIDs[0]))
        let secondEnemyFocus = BoardFocusID.promptElement(.enemy(enemyIDs[1]))
        let thirdEnemyFocus = BoardFocusID.promptElement(.enemy(enemyIDs[2]))
        let overflowEnemyFocus = BoardFocusID.promptElement(.enemy(enemyIDs[3]))

        #expect(graph.order.filter { graph.node(for: $0)?.zone == BoardFocusZone.enemyLocations }
            == [locationFocus, firstEnemyFocus, secondEnemyFocus, thirdEnemyFocus])
        #expect(graph.neighbor(from: locationFocus, direction: .right) == firstEnemyFocus)
        #expect(graph.neighbor(from: firstEnemyFocus, direction: .right) == secondEnemyFocus)
        #expect(graph.neighbor(from: secondEnemyFocus, direction: .right) == thirdEnemyFocus)
        #expect(!graph.contains(overflowEnemyFocus))
    }

    @Test("Full player area visibility controls hand and play card focus nodes")
    func hiddenPlayerAreaCardsDoNotReceiveFocusNodes() {
        let activeID = BoardTestFixtures.investigatorID("c01001")
        let promptOwnerID = BoardTestFixtures.investigatorID("c01002")
        let activePlayerID = BoardTestFixtures.playerID("000000000461")
        let promptPlayerID = BoardTestFixtures.playerID("000000000462")
        let hiddenCardID = BoardTestFixtures.cardID("000000000463")
        let visibleCardID = BoardTestFixtures.cardID("000000000464")
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: [
                activeID: BoardTestFixtures.investigator(
                    id: activeID,
                    hand: [playerCard(id: hiddenCardID)],
                    playerID: activePlayerID
                ),
                promptOwnerID: BoardTestFixtures.investigator(
                    id: promptOwnerID,
                    hand: [playerCard(id: visibleCardID)],
                    playerID: promptPlayerID
                ),
            ],
            playerOrder: [activeID, promptOwnerID],
            activeInvestigatorID: activeID,
            cardValues: [
                hiddenCardID: playerCard(id: hiddenCardID),
                visibleCardID: playerCard(id: visibleCardID),
            ]
        ))
        let hiddenFocus = BoardFocusID.promptElement(.playerCard(.card(hiddenCardID)))
        let visibleFocus = BoardFocusID.promptElement(.playerCard(.card(visibleCardID)))
        let ids = BoardFocusGraphBuilder.investigatorFocusIDs(
            projection: projection,
            choiceLinks: [
                .playerCard(.card(hiddenCardID)): [BoardLinkedChoice(
                    choiceIndex: 31,
                    title: "Hidden card",
                    isActionable: true
                )],
                .playerCard(.card(visibleCardID)): [BoardLinkedChoice(
                    choiceIndex: 32,
                    title: "Visible card",
                    isActionable: true
                )],
            ],
            fullPlayerAreaPlayerID: promptPlayerID
        )

        #expect(!ids.contains(hiddenFocus))
        #expect(ids.contains(visibleFocus))
    }

    @Test("Read-only linked choices are not focusable and cannot submit")
    func readOnlyLinkedEnemyIsNotFocusableOrSubmitted() {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let playerID = BoardTestFixtures.playerID("000000000001")
        let enemyID = BoardTestFixtures.enemyID("000000000471")
        let projection = enemyProjection(
            investigatorID: investigatorID,
            playerID: playerID,
            enemyIDs: [enemyID]
        )
        let prompt = enemyPrompt(
            choices: [fightChoice(index: 7, enemyID: enemyID)],
            ownerID: playerID,
            readOnlyReason: .anotherPlayer
        )
        var submittedChoices: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            localPlayerID: playerID,
            onChoice: { submittedChoices.append($0) }
        )
        let enemyFocus = BoardFocusID.promptElement(.enemy(enemyID))

        #expect(!controller.coordinator.graph.contains(enemyFocus))
        #expect(!controller.handle(focusID: enemyFocus, .command(.primaryAction)))
        #expect(submittedChoices.isEmpty)
    }

    private func playerCard(id: WireCardID) -> JSONValue {
        .object([
            "tag": .string("PlayerCard"),
            "contents": .object([
                "id": .string(id.codingKey.stringValue),
                "cardCode": .string("c01020"),
                "name": .object(["title": .string("Machete")]),
            ]),
        ])
    }
}
