@testable import ArkhamHorrorShared
import Testing

private let exhaustiveEnemyActionRootCases = (1 ... 5).flatMap { count in
    (0 ..< count).map { rootIndex in (count, rootIndex) }
}

@Suite("Board linked enemy action reachability properties")
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
struct EnemyActionReachabilityPropertyTests {
    @Test(
        "All connected graphs up to five locations keep headers and actions reachable",
        arguments: exhaustiveEnemyActionRootCases
    )
    func exhaustiveConnectedGraphsUpToFiveLocationsStayReachable(
        locationCount: Int,
        rootIndex: Int
    ) throws {
        for edges in connectedGraphs(locationCount: locationCount) {
            try assertReachabilityInvariants(
                locationCount: locationCount,
                edges: edges,
                rootIndex: rootIndex
            )
        }
    }

    @Test(
        "Seeded larger connected graphs keep headers and actions reachable",
        arguments: [6, 7]
    )
    func sampledLargerConnectedGraphsStayReachable(locationCount: Int) throws {
        for edges in sampledConnectedGraphs(locationCount: locationCount, sampleCount: 12) {
            try assertReachabilityInvariants(
                locationCount: locationCount,
                edges: edges,
                rootIndex: 0
            )
        }
    }

    private func assertReachabilityInvariants(
        locationCount: Int,
        edges: [(Int, Int)],
        rootIndex: Int
    ) throws {
        let ids = locationIDs(count: locationCount)
        let rootID = ids[rootIndex]
        let baselineProjection = makeProjection(ids: ids, edges: edges, actionLocations: [])
        let layout = BoardLayoutBuilder.makeLayout(
            locations: baselineProjection.locations,
            preferredRootID: rootID
        )
        let baselineGraph = makeLocationGraph(
            locations: baselineProjection.locations,
            enemiesByLocationID: [:],
            choiceLinks: [:],
            layout: layout
        )
        for actionLocations in actionPlacements(locationCount: locationCount) {
            let enemyIDs = actionLocations.indices.map { enemyID($0) }
            let graph = makeLocationGraph(
                locations: baselineProjection.locations,
                enemiesByLocationID: enemiesByLocation(
                    ids: ids,
                    actionLocations: actionLocations,
                    enemyIDs: enemyIDs
                ),
                choiceLinks: enemyChoiceLinks(enemyIDs: enemyIDs),
                layout: layout
            )
            try assertReachableLocationsAndActions(
                graph: graph,
                ids: ids,
                actionLocations: actionLocations,
                edges: edges,
                rootIndex: rootIndex
            )
            try assertEnemyActionTopologyMatchesHeaderOnlyGraph(
                graph: graph,
                baselineGraph: baselineGraph,
                ids: ids,
                layout: layout,
                actionLocations: actionLocations,
                edges: edges,
                rootIndex: rootIndex
            )
        }
    }

    private func assertReachableLocationsAndActions(
        graph: FocusGraph,
        ids: [LocationID],
        actionLocations: [Int],
        edges: [(Int, Int)],
        rootIndex: Int
    ) throws {
        let entry = try #require(graph.zoneEntryPoints[BoardFocusZone.locations])
        let reachable = reachableIDs(from: entry, in: graph)
        let reachableHeaders = locationHeaders(in: reachable, graph: graph)
        let expectedHeaders = Set(ids.map(BoardFocusID.location))
        let expectedActions = Set(actionLocations.map {
            BoardFocusID.locationEnemyActions(ids[$0])
        })
        guard reachableHeaders.isSuperset(of: expectedHeaders),
              reachable.isSuperset(of: expectedActions)
        else {
            throw invariantFailure(
                "reachability failed: reachableHeaders=\(sortedDescriptions(reachableHeaders)) "
                    + "expectedHeaders=\(sortedDescriptions(expectedHeaders)) "
                    + "reachableActions="
                    + "\(sortedDescriptions(reachable.intersection(expectedActions))) "
                    + "expectedActions=\(sortedDescriptions(expectedActions))",
                edges: edges,
                rootIndex: rootIndex,
                actionLocations: actionLocations
            )
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func assertEnemyActionTopologyMatchesHeaderOnlyGraph(
        graph: FocusGraph,
        baselineGraph: FocusGraph,
        ids: [LocationID],
        layout: BoardLayout,
        actionLocations: [Int],
        edges: [(Int, Int)],
        rootIndex: Int
    ) throws {
        for index in ids.indices {
            for direction in FocusDirection.allCases {
                let headerFailure = headerTopologyFailure(
                    graph: graph,
                    baselineGraph: baselineGraph,
                    ids: ids,
                    headerIndex: index,
                    direction: direction
                )
                guard headerFailure == nil else {
                    throw invariantFailure(
                        headerFailure ?? "header topology failed",
                        edges: edges,
                        rootIndex: rootIndex,
                        actionLocations: actionLocations
                    )
                }
            }
        }
        for actionIndex in actionLocations {
            let pairFailure = actionHeaderPairFailure(
                graph: graph,
                ids: ids,
                actionIndex: actionIndex
            )
            guard pairFailure == nil else {
                throw invariantFailure(
                    pairFailure ?? "action-header pair failed",
                    edges: edges,
                    rootIndex: rootIndex,
                    actionLocations: actionLocations
                )
            }
            for direction in [FocusDirection.down, .left, .right] {
                let actionFailure = actionTopologyFailure(
                    graph: graph,
                    baselineGraph: baselineGraph,
                    ids: ids,
                    layout: layout,
                    actionIndex: actionIndex,
                    direction: direction
                )
                guard actionFailure == nil else {
                    throw invariantFailure(
                        actionFailure ?? "action topology failed",
                        edges: edges,
                        rootIndex: rootIndex,
                        actionLocations: actionLocations
                    )
                }
            }
        }
    }

    private func actionHeaderPairFailure(
        graph: FocusGraph,
        ids: [LocationID],
        actionIndex: Int
    ) -> String? {
        let locationID = ids[actionIndex]
        let headerID = BoardFocusID.location(locationID)
        let actionID = BoardFocusID.locationEnemyActions(locationID)
        let headerDown = explicitNeighbor(in: graph, from: headerID, direction: .down)
        guard headerDown == actionID else {
            return "header \(headerID) down is \(describe(headerDown)); expected \(actionID)"
        }
        let actionUp = explicitNeighbor(in: graph, from: actionID, direction: .up)
        return actionUp == headerID ? nil : "action \(actionID) up is "
            + "\(describe(actionUp)); expected \(headerID)"
    }

    private func headerTopologyFailure(
        graph: FocusGraph,
        baselineGraph: FocusGraph,
        ids: [LocationID],
        headerIndex: Int,
        direction: FocusDirection
    ) -> String? {
        let locationID = ids[headerIndex]
        let headerID = BoardFocusID.location(locationID)
        let baselineTarget = explicitNeighbor(
            in: baselineGraph,
            from: headerID,
            direction: direction
        )
        let target = explicitNeighbor(in: graph, from: headerID, direction: direction)
        guard target != baselineTarget else { return nil }
        guard let actionLocationIndex = actionLocationIndex(
            forActionID: target,
            ids: ids,
            graph: graph
        ) else {
            return "header \(headerID) \(direction) changed from \(describe(baselineTarget)) "
                + "to non-action target \(describe(target))"
        }
        let actionLocationID = ids[actionLocationIndex]
        let actionID = BoardFocusID.locationEnemyActions(actionLocationID)
        let actionLocationHeaderID = BoardFocusID.location(actionLocationID)
        if direction == .down, actionLocationIndex == headerIndex {
            let actionDown = explicitNeighbor(in: graph, from: actionID, direction: .down)
            if baselineTarget == nil {
                return actionDown == actionID ? nil : "single-location header \(headerID) "
                    + "down inserts \(actionID), but action down is \(describe(actionDown))"
            }
            return actionDown == baselineTarget ? nil : "header \(headerID) down inserts "
                + "\(actionID), but action down is \(describe(actionDown)); expected "
                + "original down target \(describe(baselineTarget))"
        }
        return baselineTarget == actionLocationHeaderID ? nil : "header \(headerID) "
            + "\(direction) changed from \(describe(baselineTarget)) to \(actionID), "
            + "but the header-only edge did not point at \(actionLocationHeaderID)"
    }

    // swiftlint:disable:next function_parameter_count
    private func actionTopologyFailure(
        graph: FocusGraph,
        baselineGraph: FocusGraph,
        ids: [LocationID],
        layout: BoardLayout,
        actionIndex: Int,
        direction: FocusDirection
    ) -> String? {
        let locationID = ids[actionIndex]
        let headerID = BoardFocusID.location(locationID)
        let actionID = BoardFocusID.locationEnemyActions(locationID)
        let headerBaseTarget = headerBaseFocusTarget(
            from: actionIndex,
            direction: direction,
            ids: ids,
            layout: layout
        )
        let target = explicitNeighbor(in: graph, from: actionID, direction: direction)
        if headerBaseTarget == nil {
            return target == actionID ? nil : "action \(actionID) \(direction) is "
                + "\(describe(target)); expected self because the header-only graph has no target"
        }
        guard target == headerBaseTarget else {
            return "action \(actionID) \(direction) is \(describe(target)); expected "
                + "header-only target \(describe(headerBaseTarget))"
        }
        return reciprocalTopologyFailure(
            graph: graph,
            baselineGraph: baselineGraph,
            ids: ids,
            layout: layout,
            headerID: headerID,
            actionID: actionID,
            target: target,
            direction: direction
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func reciprocalTopologyFailure(
        graph: FocusGraph,
        baselineGraph: FocusGraph,
        ids: [LocationID],
        layout: BoardLayout,
        headerID: SemanticFocusID,
        actionID: SemanticFocusID,
        target: SemanticFocusID?,
        direction: FocusDirection
    ) -> String? {
        guard let target,
              let targetIndex = ids.firstIndex(where: { BoardFocusID.location($0) == target })
        else { return nil }
        let reverse = direction.boardOppositeForTest
        let headerBaseReturn = headerBaseFocusTarget(
            from: targetIndex,
            direction: reverse,
            ids: ids,
            layout: layout
        )
        guard headerBaseReturn == headerID else { return nil }
        let returnTarget = explicitNeighbor(in: graph, from: target, direction: reverse)
        if returnTarget == actionID {
            return nil
        }
        let baselineReturn = explicitNeighbor(in: baselineGraph, from: target, direction: reverse)
        let repairRestoredHeaderSlot = (reverse == .left || reverse == .right)
            && returnTarget == baselineReturn
            && returnTarget != headerID
        return repairRestoredHeaderSlot ? nil : "action \(actionID) \(direction) reaches "
            + "\(target), whose \(reverse) return is \(describe(returnTarget)); expected "
            + "\(actionID) unless the reachability repair rewrote that slot to "
            + "the exact no-actions target \(describe(baselineReturn))"
    }

    private func explicitNeighbor(
        in graph: FocusGraph,
        from id: SemanticFocusID,
        direction: FocusDirection
    ) -> SemanticFocusID? {
        graph.node(for: id)?.neighbors[direction]
    }

    private func actionLocationIndex(
        forActionID id: SemanticFocusID?,
        ids: [LocationID],
        graph: FocusGraph
    ) -> Int? {
        guard let id, graph.node(for: id)?.zone == BoardFocusZone.locations,
              id.rawValue.contains("enemyActions")
        else { return nil }
        return ids.firstIndex { BoardFocusID.locationEnemyActions($0) == id }
    }

    private func headerBaseFocusTarget(
        from index: Int,
        direction: FocusDirection,
        ids: [LocationID],
        layout: BoardLayout
    ) -> SemanticFocusID? {
        headerBaseTarget(from: index, direction: direction, ids: ids, layout: layout)
            .map(BoardFocusID.location)
    }

    private func headerBaseTarget(
        from index: Int,
        direction: FocusDirection,
        ids: [LocationID],
        layout: BoardLayout
    ) -> LocationID? {
        let locationID = ids[index]
        if let layoutTarget = (layout.neighbors[locationID] ?? [:])[direction] {
            return layoutTarget
        }
        guard ids.count > 1 else { return nil }
        return fallbackTarget(from: index, direction: direction, ids: ids)
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

    private func makeLocationGraph(
        locations: [BoardLocationNode],
        enemiesByLocationID: [LocationID: [BoardEnemyNode]],
        choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]],
        layout: BoardLayout
    ) -> FocusGraph {
        var nodes: [FocusNode] = []
        var zoneEntryPoints: [SemanticFocusZone: SemanticFocusID] = [:]
        BoardFocusGraphBuilder.appendLocations(
            locations,
            enemiesByLocationID: enemiesByLocationID,
            choiceLinks: choiceLinks,
            layout: layout,
            nodes: &nodes,
            zoneEntryPoints: &zoneEntryPoints
        )
        return FocusGraph(
            nodes: nodes,
            zoneEntryPoints: zoneEntryPoints,
            wrapPolicy: .wrapWithinZone
        )
    }

    private func enemiesByLocation(
        ids: [LocationID],
        actionLocations: [Int],
        enemyIDs: [EnemyID]
    ) -> [LocationID: [BoardEnemyNode]] {
        Dictionary(
            uniqueKeysWithValues: zip(actionLocations, enemyIDs).map { locationIndex, enemyID in
                let locationID = ids[locationIndex]
                return (locationID, [enemyNode(enemyID, locationID: locationID)])
            }
        )
    }

    private func enemyChoiceLinks(
        enemyIDs: [EnemyID]
    ) -> [BoardPromptElementID: [BoardLinkedChoice]] {
        Dictionary(uniqueKeysWithValues: enemyIDs.enumerated().map { offset, enemyID in
            (
                BoardPromptElementID.enemy(enemyID),
                [BoardLinkedChoice(
                    choiceIndex: 100 + offset,
                    title: "Fight Enemy",
                    isActionable: true
                )]
            )
        })
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

    private func enemyNode(_ id: EnemyID, locationID: LocationID) -> BoardEnemyNode {
        BoardEnemyNode(
            id: id,
            cardCode: nil,
            displayName: "Enemy \(id)",
            fight: nil,
            health: nil,
            evade: nil,
            damage: nil,
            horror: nil,
            attackDamage: nil,
            attackHorror: nil,
            exhausted: false,
            engagedInvestigatorID: nil,
            locationID: locationID,
            tokenCounts: []
        )
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
        var samples: [[(Int, Int)]] = []
        while samples.count < sampleCount {
            let edges = pairs.filter { _ in generator.nextBool() }
            if isConnected(locationCount: locationCount, edges: edges) {
                samples.append(edges)
            }
        }
        return samples
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

    private func invariantFailure(
        _ message: String,
        edges: [(Int, Int)],
        rootIndex: Int,
        actionLocations: [Int]
    ) -> InvariantFailure {
        InvariantFailure(
            message: message,
            edges: edges,
            rootIndex: rootIndex,
            actionLocations: actionLocations
        )
    }

    private func sortedDescriptions(_ ids: Set<SemanticFocusID>) -> [String] {
        ids.map(\.rawValue).sorted()
    }

    private func describe(_ id: SemanticFocusID?) -> String {
        id?.rawValue ?? "nil"
    }

    private struct InvariantFailure: Error, CustomStringConvertible {
        var message: String; var edges: [(Int, Int)]; var rootIndex: Int
        var actionLocations: [Int]

        var description: String {
            "\(message); edges=\(edges); rootIndex=\(rootIndex); "
                + "actionLocations=\(actionLocations)"
        }
    }

    private struct SeededGenerator {
        var state: UInt64
        mutating func nextBool() -> Bool {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            value ^= value >> 31
            return ((value >> 63) & 1) == 1
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
