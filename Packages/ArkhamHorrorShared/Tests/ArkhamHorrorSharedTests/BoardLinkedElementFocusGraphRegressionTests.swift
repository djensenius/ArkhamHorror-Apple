@testable import ArkhamHorrorShared
import Testing

@MainActor
@Suite("Board linked element focus graph regressions")
// swiftlint:disable:next type_body_length
struct BoardLinkedFocusGraphTests {
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

    @Test("Location enemy actions precede the original down neighbor")
    // swiftlint:disable:next function_body_length
    func locationEnemyActionsAreReachableBeforeOriginalDownNeighbor() {
        let rootID = BoardTestFixtures.locationID("000000000441")
        let locationID = BoardTestFixtures.locationID("000000000442")
        let downLocationID = BoardTestFixtures.locationID("000000000443")
        let rightLocationID = BoardTestFixtures.locationID("000000000449")
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
                    connectedLocations: [rootID, downLocationID, rightLocationID],
                    enemies: [firstEnemyID, secondEnemyID]
                ))),
                (downLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: downLocationID,
                    connectedLocations: [rootID, locationID]
                ))),
                (rightLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: rightLocationID,
                    connectedLocations: [locationID]
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
        let rightLocationFocus = BoardFocusID.location(rightLocationID)
        let actionsFocus = BoardFocusID.locationEnemyActions(locationID)
        let firstEnemyFocus = BoardFocusID.promptElement(.enemy(firstEnemyID))
        let secondEnemyFocus = BoardFocusID.promptElement(.enemy(secondEnemyID))
        var submittedChoices: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onChoice: { submittedChoices.append($0) }
        )

        #expect(layout.neighbors[locationID]?[.down] == downLocationID)
        #expect(graph.node(for: actionsFocus)?.zone == BoardFocusZone.locations)
        #expect(!graph.contains(firstEnemyFocus))
        #expect(!graph.contains(secondEnemyFocus))
        #expect(graph.neighbor(from: locationFocus, direction: .down) == actionsFocus)
        #expect(graph.neighbor(from: actionsFocus, direction: .up) == locationFocus)
        #expect(graph.neighbor(from: actionsFocus, direction: .down) == downLocationFocus)
        #expect(graph.neighbor(from: actionsFocus, direction: .left) == BoardFocusID.location(
            rootID
        ))
        #expect(graph.neighbor(from: BoardFocusID.location(rootID), direction: .right)
            == actionsFocus)
        #expect(graph.neighbor(from: actionsFocus, direction: .right) == rightLocationFocus)
        #expect(graph.neighbor(from: rightLocationFocus, direction: .left) == actionsFocus)
        #expect(graph.neighbor(from: downLocationFocus, direction: .up) == actionsFocus)
        #expect(controller.handle(focusID: actionsFocus, .command(.primaryAction)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.linkedChoiceMenuChoice(7))
        #expect(controller.handle(.command(.focusMove(.down))))
        #expect(controller.coordinator.currentFocus == BoardFocusID.linkedChoiceMenuChoice(8))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submittedChoices == [8])
    }

    @Test("Collision-resolved enemy action edges do not leave one-way shared-neighbor trips")
    // swiftlint:disable:next function_body_length
    func collisionResolvedEnemyActionEdgesAvoidOneWaySharedNeighborTrips() {
        let rootID = BoardTestFixtures.locationID("000000000480")
        let firstActionLocationID = BoardTestFixtures.locationID("000000000481")
        let secondActionLocationID = BoardTestFixtures.locationID("000000000482")
        let sharedNeighborID = BoardTestFixtures.locationID("000000000483")
        let firstEnemyID = BoardTestFixtures.enemyID("000000000484")
        let secondEnemyID = BoardTestFixtures.enemyID("000000000485")
        let projection = locationEnemyProjection(
            locations: [
                (rootID, .ordinary(BoardTestFixtures.ordinaryLocation(id: rootID))),
                (firstActionLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: firstActionLocationID,
                    enemies: [firstEnemyID]
                ))),
                (secondActionLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: secondActionLocationID,
                    enemies: [secondEnemyID]
                ))),
                (sharedNeighborID, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: sharedNeighborID
                ))),
            ],
            enemyIDs: [firstEnemyID, secondEnemyID]
        )
        let layout = BoardLayout(
            positions: [
                rootID: BoardGridPosition(column: 0, row: 0),
                firstActionLocationID: BoardGridPosition(column: 1, row: 0),
                secondActionLocationID: BoardGridPosition(column: 1, row: 1),
                sharedNeighborID: BoardGridPosition(column: 2, row: 0),
            ],
            neighbors: [
                rootID: [.right: firstActionLocationID],
                firstActionLocationID: [.left: rootID, .right: sharedNeighborID],
                secondActionLocationID: [.left: rootID, .right: sharedNeighborID],
                sharedNeighborID: [.left: firstActionLocationID],
            ],
            connections: [],
            columnCount: 3,
            rowCount: 2
        )
        let graph = BoardFocusGraphBuilder.makeGraph(
            projection: projection,
            layout: layout,
            prompt: enemyPrompt(choices: [
                fightChoice(index: 7, enemyID: firstEnemyID),
                fightChoice(index: 8, enemyID: secondEnemyID),
            ])
        )
        let rootFocus = BoardFocusID.location(rootID)
        let firstActionLocationFocus = BoardFocusID.location(firstActionLocationID)
        let firstActionsFocus = BoardFocusID.locationEnemyActions(firstActionLocationID)
        let secondActionsFocus = BoardFocusID.locationEnemyActions(secondActionLocationID)
        let sharedNeighborFocus = BoardFocusID.location(sharedNeighborID)

        #expect(graph.neighbor(from: firstActionsFocus, direction: .left) == rootFocus)
        #expect(graph.neighbor(from: rootFocus, direction: .right) == firstActionsFocus)
        #expect(graph.neighbor(from: secondActionsFocus, direction: .left) == rootFocus)
        #expect(graph.neighbor(from: firstActionLocationFocus, direction: .right)
            == sharedNeighborFocus)
        #expect(graph.neighbor(from: firstActionsFocus, direction: .right) == sharedNeighborFocus)
        #expect(graph.neighbor(from: sharedNeighborFocus, direction: .left) == firstActionsFocus)
        #expect(graph.neighbor(from: secondActionsFocus, direction: .right) == sharedNeighborFocus)
    }

    @Test("Enemy-location action container reaches every linked enemy")
    func enemyLocationActionContainerReachesEveryLinkedEnemy() {
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
        let actionsFocus = BoardFocusID.enemyLocationEnemyActions(enemyLocationID)
        let enemyFocuses = enemyIDs.map { BoardFocusID.promptElement(.enemy($0)) }
        var submittedChoices: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onChoice: { submittedChoices.append($0) }
        )

        #expect(graph.order.filter { graph.node(for: $0)?.zone == BoardFocusZone.enemyLocations }
            == [locationFocus, actionsFocus])
        #expect(graph.neighbor(from: locationFocus, direction: .right) == actionsFocus)
        #expect(enemyFocuses.allSatisfy { !graph.contains($0) })
        #expect(controller.handle(focusID: actionsFocus, .command(.primaryAction)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.linkedChoiceMenuChoice(20))
        for expectedIndex in [21, 22, 23] {
            #expect(controller.handle(.command(.focusMove(.down))))
            #expect(controller.coordinator.currentFocus == BoardFocusID.linkedChoiceMenuChoice(
                expectedIndex
            ))
        }
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submittedChoices == [23])
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
