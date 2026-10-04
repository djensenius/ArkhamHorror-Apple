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
            locations: [
                location(firstLocationID, connectedTo: [secondLocationID], enemies: [enemyID]),
                location(secondLocationID, connectedTo: [firstLocationID]),
            ],
            enemyIDs: [enemyID]
        )
        let layout = BoardLayoutBuilder.makeLayout(
            locations: projection.locations,
            preferredRootID: firstLocationID
        )
        let graph = makeGraph(
            projection: projection,
            layout: layout,
            choices: [fightChoice(index: 7, enemyID: enemyID)]
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

    @Test("Header wrap targets stay reachable when a location has enemy actions")
    func headerWrapTargetsStayReachableWithEnemyActions() {
        let locationA = BoardTestFixtures.locationID("0000000004a0")
        let locationB = BoardTestFixtures.locationID("0000000004b0")
        let locationC = BoardTestFixtures.locationID("0000000004c0")
        let locationD = BoardTestFixtures.locationID("0000000004d0")
        let enemyID = BoardTestFixtures.enemyID("0000000004e0")
        let projection = makeProjection(
            locations: [
                location(locationA, connectedTo: [locationB, locationC, locationD]),
                location(locationB, connectedTo: [locationA, locationD], enemies: [enemyID]),
                location(locationC, connectedTo: [locationA]),
                location(locationD, connectedTo: [locationA, locationB]),
            ],
            enemyIDs: [enemyID]
        )
        let layout = BoardLayoutBuilder.makeLayout(
            locations: projection.locations,
            preferredRootID: locationA
        )
        let graph = makeGraph(
            projection: projection,
            layout: layout,
            choices: [fightChoice(index: 7, enemyID: enemyID)]
        )
        let focusA = BoardFocusID.location(locationA)
        let focusB = BoardFocusID.location(locationB)
        let focusC = BoardFocusID.location(locationC)
        let focusD = BoardFocusID.location(locationD)
        let actionsB = BoardFocusID.locationEnemyActions(locationB)

        #expect(layout.neighbors[locationB]?[.right] == nil)
        #expect(graph.neighbor(from: focusB, direction: .right) == focusC)
        #expect(reachableHeaders(from: focusA, in: graph).isSuperset(of: [
            focusA, focusB, focusC, focusD,
        ]))
        #expect(graph.neighbor(from: focusA, direction: .right) == actionsB)
        #expect(graph.neighbor(from: actionsB, direction: .left) == focusA)
        #expect(graph.neighbor(from: focusB, direction: .down) == actionsB)
        #expect(graph.neighbor(from: actionsB, direction: .up) == focusB)
        #expect(graph.neighbor(from: actionsB, direction: .down) == focusD)
        #expect(graph.neighbor(from: focusD, direction: .up) == actionsB)
    }

    @Test("Every generated board location header is reachable from the locations entry")
    func generatedBoardHeadersStayReachableFromEntry() throws {
        for board in generatedBoards() {
            let projection = makeProjection(locations: board.locations, enemyIDs: board.enemyIDs)
            let layout = BoardLayoutBuilder.makeLayout(
                locations: projection.locations,
                preferredRootID: board.rootID
            )
            let graph = makeGraph(
                projection: projection,
                layout: layout,
                choices: board.enemyIDs.enumerated().map { offset, enemyID in
                    fightChoice(index: 20 + offset, enemyID: enemyID)
                }
            )
            let entry = try #require(graph.zoneEntryPoints[BoardFocusZone.locations])
            let reachable = reachableHeaders(from: entry, in: graph)
            let expectedHeaders = Set(board.locations.map { BoardFocusID.location($0.0) })

            #expect(reachable.isSuperset(of: expectedHeaders))
        }
    }

    private func makeGraph(
        projection: BoardProjection,
        layout: BoardLayout,
        choices: [BasicChoice]
    ) -> FocusGraph {
        BoardFocusGraphBuilder.makeGraph(
            projection: projection,
            layout: layout,
            prompt: enemyPrompt(choices: choices)
        )
    }

    private func makeProjection(
        locations: [(LocationID, Location)],
        enemyIDs: [EnemyID]
    ) -> BoardProjection {
        BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: locations,
            enemyValues: Dictionary(uniqueKeysWithValues: enemyIDs.map { ($0, .null) })
        ))
    }

    private func location(
        _ id: LocationID,
        connectedTo connectedLocationIDs: [LocationID] = [],
        enemies: [EnemyID] = []
    ) -> (LocationID, Location) {
        (id, .ordinary(BoardTestFixtures.ordinaryLocation(
            id: id,
            connectedLocations: connectedLocationIDs,
            enemies: enemies
        )))
    }

    private func reachableHeaders(
        from entry: SemanticFocusID,
        in graph: FocusGraph
    ) -> Set<SemanticFocusID> {
        var visited: Set<SemanticFocusID> = []
        var queue = [entry]
        while let current = queue.first {
            queue.removeFirst()
            guard visited.insert(current).inserted else { continue }
            for direction in FocusDirection.allCases {
                guard let next = graph.neighbor(
                    from: current,
                    direction: direction
                ) else { continue }
                if !visited.contains(next) {
                    queue.append(next)
                }
            }
        }
        return Set(visited.filter { id in
            graph.node(for: id)?.zone == BoardFocusZone.locations
                && !id.rawValue.contains("enemyActions")
        })
    }

    private func generatedBoards() -> [GeneratedBoard] {
        let firstEnemy = BoardTestFixtures.enemyID("0000000005e1")
        let secondEnemy = BoardTestFixtures.enemyID("0000000005e2")
        return [
            generatedBoard(
                base: "00000000051", connections: [(0, 1), (1, 2), (2, 3)],
                enemyPlacements: [(1, firstEnemy)]
            ),
            generatedBoard(
                base: "00000000052", connections: [(0, 1), (0, 2), (0, 3), (1, 3)],
                enemyPlacements: [(1, firstEnemy)]
            ),
            generatedBoard(
                base: "00000000053", connections: [(0, 1), (1, 2), (2, 3), (3, 4), (4, 0)],
                enemyPlacements: [(1, firstEnemy), (3, secondEnemy)]
            ),
        ]
    }

    private func generatedBoard(
        base: String,
        connections: [(Int, Int)],
        enemyPlacements: [(Int, EnemyID)]
    ) -> GeneratedBoard {
        let ids = (0 ..< ((connections.flatMap { [$0.0, $0.1] }.max() ?? 0) + 1)).map {
            BoardTestFixtures.locationID("\(base)\($0)")
        }
        let enemyByLocation = Dictionary(uniqueKeysWithValues: enemyPlacements)
        let locationTuples = ids.enumerated().map { index, id in
            location(
                id,
                connectedTo: connections.compactMap { first, second in
                    first == index ? ids[second] : nil
                },
                enemies: enemyByLocation[index].map { [$0] } ?? []
            )
        }
        return GeneratedBoard(
            rootID: ids[0],
            locations: locationTuples,
            enemyIDs: enemyPlacements.map(\.1)
        )
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

    private struct GeneratedBoard {
        var rootID: LocationID
        var locations: [(LocationID, Location)]
        var enemyIDs: [EnemyID]
    }
}
