@testable import ArkhamHorrorShared
import Testing

@MainActor
@Suite("Board linked enemy action reachability properties")
// swiftlint:disable:next type_body_length
struct EnemyActionReachabilityPropertyTests {
    @Test("All connected graphs up to five locations keep headers and actions reachable")
    func exhaustiveConnectedGraphsUpToFiveLocationsStayReachable() throws {
        for count in 1 ... 5 {
            for edges in connectedGraphs(locationCount: count) {
                try assertReachabilityInvariants(locationCount: count, edges: edges)
            }
        }
    }

    @Test("Seeded larger connected graphs keep headers and actions reachable")
    func sampledLargerConnectedGraphsStayReachable() throws {
        for count in 6 ... 7 {
            for edges in sampledConnectedGraphs(locationCount: count, sampleCount: 12) {
                try assertReachabilityInvariants(locationCount: count, edges: edges)
            }
        }
    }

    private func assertReachabilityInvariants(
        locationCount: Int,
        edges: [(Int, Int)]
    ) throws {
        let ids = locationIDs(count: locationCount)
        let baselineProjection = makeProjection(ids: ids, edges: edges, actionLocations: [])
        let layout = BoardLayoutBuilder.makeLayout(
            locations: baselineProjection.locations,
            preferredRootID: ids[0]
        )
        let baselineGraph = makeGraph(projection: baselineProjection, layout: layout, choices: [])
        let baselineEntry = try #require(baselineGraph.zoneEntryPoints[BoardFocusZone.locations])
        let baselineHeaders = reachableHeaders(from: baselineEntry, in: baselineGraph)

        for actionLocations in actionPlacements(locationCount: locationCount) {
            let enemyIDs = actionLocations.indices.map { enemyID($0) }
            let projection = makeProjection(
                ids: ids,
                edges: edges,
                actionLocations: actionLocations,
                enemyIDs: enemyIDs
            )
            let graph = makeGraph(
                projection: projection,
                layout: layout,
                choices: enemyIDs.enumerated().map { offset, enemyID in
                    fightChoice(index: 100 + offset, enemyID: enemyID)
                }
            )
            let entry = try #require(graph.zoneEntryPoints[BoardFocusZone.locations])
            let reachable = reachableIDs(from: entry, in: graph)
            let reachableHeaders = locationHeaders(in: reachable, graph: graph)
            let expectedHeaders = Set(ids.map(BoardFocusID.location))
            let expectedActions = Set(actionLocations.map {
                BoardFocusID.locationEnemyActions(ids[$0])
            })

            #expect(
                reachableHeaders.isSuperset(of: expectedHeaders)
                    && reachableHeaders.isSuperset(of: baselineHeaders)
                    && reachable.isSuperset(of: expectedActions)
                    && reciprocityHolds(
                        graph: graph,
                        layout: layout,
                        ids: ids,
                        actionLocations: actionLocations
                    )
            )
        }
    }

    private func reciprocityHolds(
        graph: FocusGraph,
        layout: BoardLayout,
        ids: [LocationID],
        actionLocations: [Int]
    ) -> Bool {
        let reciprocalClaims = uniqueReciprocalClaims(
            layout: layout,
            ids: ids,
            actionLocations: actionLocations
        )
        for actionIndex in actionLocations {
            let locationID = ids[actionIndex]
            let headerID = BoardFocusID.location(locationID)
            let actionID = BoardFocusID.locationEnemyActions(locationID)
            guard graph.neighbor(from: actionID, direction: .up) == headerID,
                  graph.neighbor(from: headerID, direction: .down) == actionID
            else { return false }

            for direction in [FocusDirection.down, .left, .right] {
                let reverse = direction.boardOppositeForTest
                guard let targetID = graph.neighbor(from: actionID, direction: direction) else {
                    continue
                }
                if targetID == actionID {
                    continue
                }
                let claim = ReverseClaim(target: targetID, direction: reverse)
                if reciprocalClaims[claim] == actionID {
                    let returnTarget = graph.neighbor(from: targetID, direction: reverse)
                    guard returnTarget == actionID || isLocationHeader(returnTarget, graph: graph)
                    else { return false }
                }
            }
        }
        return true
    }

    private func uniqueReciprocalClaims(
        layout: BoardLayout,
        ids: [LocationID],
        actionLocations: [Int]
    ) -> [ReverseClaim: SemanticFocusID] {
        guard ids.count > 1 else { return [:] }
        var groupedClaims: [ReverseClaim: [SemanticFocusID]] = [:]
        for actionIndex in actionLocations {
            let locationID = ids[actionIndex]
            let actionID = BoardFocusID.locationEnemyActions(locationID)
            for direction in [FocusDirection.down, .left, .right] {
                let reverse = direction.boardOppositeForTest
                let targetID = headerBaseTarget(
                    from: actionIndex,
                    direction: direction,
                    ids: ids,
                    layout: layout
                )
                guard headerBaseTarget(
                    from: targetID,
                    direction: reverse,
                    ids: ids,
                    layout: layout
                ) == locationID else { continue }
                let claim = ReverseClaim(
                    target: BoardFocusID.location(targetID),
                    direction: reverse
                )
                groupedClaims[claim, default: []].append(actionID)
            }
        }
        return Dictionary(uniqueKeysWithValues: groupedClaims.compactMap { claim, actionIDs in
            actionIDs.count == 1 ? (claim, actionIDs[0]) : nil
        })
    }

    private func headerBaseTarget(
        from index: Int,
        direction: FocusDirection,
        ids: [LocationID],
        layout: BoardLayout
    ) -> LocationID {
        let locationID = ids[index]
        return (layout.neighbors[locationID] ?? [:])[direction]
            ?? fallbackTarget(from: index, direction: direction, ids: ids)
    }

    private func headerBaseTarget(
        from locationID: LocationID,
        direction: FocusDirection,
        ids: [LocationID],
        layout: BoardLayout
    ) -> LocationID? {
        guard let index = ids.firstIndex(of: locationID) else { return nil }
        return headerBaseTarget(from: index, direction: direction, ids: ids, layout: layout)
    }

    private func fallbackTarget(
        from index: Int,
        direction: FocusDirection,
        ids: [LocationID]
    ) -> LocationID {
        switch direction {
        case .up, .left:
            ids[(index - 1 + ids.count) % ids.count]
        case .down, .right:
            ids[(index + 1) % ids.count]
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
        ids: [LocationID],
        edges: [(Int, Int)],
        actionLocations: [Int],
        enemyIDs: [EnemyID] = []
    ) -> BoardProjection {
        let enemyByLocation = Dictionary(uniqueKeysWithValues: zip(actionLocations, enemyIDs))
        let locations = ids.enumerated().map { index, id in
            let connectedIDs = edges.compactMap { first, second in
                first == index ? ids[second] : nil
            }
            return location(
                id,
                connectedTo: connectedIDs,
                enemies: enemyByLocation[index].map { [$0] } ?? []
            )
        }
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: locations,
            enemyValues: Dictionary(uniqueKeysWithValues: enemyIDs.map { ($0, .null) })
        ))
    }

    private func location(
        _ id: LocationID,
        connectedTo connectedLocationIDs: [LocationID],
        enemies: [EnemyID]
    ) -> (LocationID, Location) {
        (id, .ordinary(BoardTestFixtures.ordinaryLocation(
            id: id,
            connectedLocations: connectedLocationIDs,
            enemies: enemies
        )))
    }

    private func reachableIDs(
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
        return visited
    }

    private func reachableHeaders(
        from entry: SemanticFocusID,
        in graph: FocusGraph
    ) -> Set<SemanticFocusID> {
        locationHeaders(in: reachableIDs(from: entry, in: graph), graph: graph)
    }

    private func locationHeaders(
        in ids: Set<SemanticFocusID>,
        graph: FocusGraph
    ) -> Set<SemanticFocusID> {
        Set(ids.filter { isLocationHeader($0, graph: graph) })
    }

    private func isLocationHeader(_ id: SemanticFocusID?, graph: FocusGraph) -> Bool {
        guard let id else { return false }
        return graph.node(for: id)?.zone == BoardFocusZone.locations
            && !id.rawValue.contains("enemyActions")
    }

    private func connectedGraphs(locationCount: Int) -> [[(Int, Int)]] {
        let pairs = edgePairs(locationCount: locationCount)
        return (0 ..< (1 << pairs.count)).compactMap { mask in
            let edges = pairs.enumerated().compactMap { offset, edge in
                (mask & (1 << offset)) != 0 ? edge : nil
            }
            return isConnected(locationCount: locationCount, edges: edges) ? edges : nil
        }
    }

    private func sampledConnectedGraphs(locationCount: Int, sampleCount: Int) -> [[(Int, Int)]] {
        let pairs = edgePairs(locationCount: locationCount)
        var generator = SeededGenerator(state: UInt64(locationCount * 1001))
        return (0 ..< sampleCount).map { _ in
            pairs.filter { $0.1 == $0.0 + 1 || generator.nextBool() }
        }
    }

    private func edgePairs(locationCount: Int) -> [(Int, Int)] {
        (0 ..< locationCount).flatMap { first in
            ((first + 1) ..< locationCount).map { second in (first, second) }
        }
    }

    private func isConnected(locationCount: Int, edges: [(Int, Int)]) -> Bool {
        guard locationCount > 1 else { return true }
        var adjacency = Array(repeating: Set<Int>(), count: locationCount)
        for (first, second) in edges {
            adjacency[first].insert(second)
            adjacency[second].insert(first)
        }
        var visited: Set = [0]
        var queue = [0]
        while let current = queue.first {
            queue.removeFirst()
            for next in adjacency[current] where visited.insert(next).inserted {
                queue.append(next)
            }
        }
        return visited.count == locationCount
    }

    private func actionPlacements(locationCount: Int) -> [[Int]] {
        let singles = (0 ..< locationCount).map { [$0] }
        let doubles = (0 ..< locationCount).flatMap { first in
            ((first + 1) ..< locationCount).map { second in [first, second] }
        }
        return singles + doubles
    }

    private func locationIDs(count: Int) -> [LocationID] {
        (0 ..< count).map { BoardTestFixtures.locationID("0000000007\($0)0") }
    }

    private func enemyID(_ index: Int) -> EnemyID {
        BoardTestFixtures.enemyID("0000000008\(index)0")
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

    private struct ReverseClaim: Hashable {
        var target: SemanticFocusID; var direction: FocusDirection
    }

    private struct SeededGenerator {
        var state: UInt64
        mutating func nextBool() -> Bool {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (state & 1) == 0
        }
    }
}

private extension FocusDirection {
    var boardOppositeForTest: FocusDirection {
        switch self {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
    }
}
