import Foundation

/// The stable ``SemanticFocusZone``s this board declares. Every zone name is a fixed
/// string literal, never derived from live entity data, so a snapshot replacement can
/// never accidentally rename a zone.
enum BoardFocusZone {
    static let scenario: SemanticFocusZone = "board.scenario"
    static let actAgenda: SemanticFocusZone = "board.actAgenda"
    static let locations: SemanticFocusZone = "board.locations"
    static let enemyLocations: SemanticFocusZone = "board.enemyLocations"
    static let investigators: SemanticFocusZone = "board.investigators"
    static let chaosBag: SemanticFocusZone = "board.chaosBag"

    /// The fixed cycling order every ``BoardCommandController/cycleZone(_:)`` call walks,
    /// deliberately declared once here rather than derived from `FocusGraph.order` (whose
    /// own order is insertion order across every zone interleaved, not a meaningful
    /// zone-level sequence).
    static let cycleOrder: [SemanticFocusZone] = [
        scenario, actAgenda, locations, enemyLocations, investigators, chaosBag,
    ]
}

/// Deterministic ``SemanticFocusID`` construction for every board entity kind. Every
/// identifier is derived from the entity's own stable snapshot identity (a UUID or card
/// code), never from array index or view-generated state, so focus survives reordering.
enum BoardFocusID {
    static let scenarioHeader: SemanticFocusID = "board.scenario.header"
    static let chaosBagSummary: SemanticFocusID = "board.chaosBag.summary"

    static func act(_ id: ActID) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.act.\(id.description)")
    }

    static func agenda(_ id: AgendaID) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.agenda.\(id.description)")
    }

    static func location(_ id: LocationID) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.location.\(id.description)")
    }

    static func enemyLocation(_ id: LocationID) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.enemyLocation.\(id.description)")
    }

    static func investigator(_ id: InvestigatorID) -> SemanticFocusID {
        SemanticFocusID(rawValue: "board.investigator.\(id.description)")
    }
}

/// Builds a deterministic ``FocusGraph`` from a ``BoardProjection`` and its matching
/// ``BoardLayout``. Every edge is either declared from real topology (ordinary locations,
/// via ``BoardLayout/neighbors``) or a simple top-to-bottom/left-to-right chain within a
/// zone (every other zone); ``FocusWrapPolicy/wrapWithinZone`` guarantees every entity
/// stays reachable by directional movement even where an explicit edge is absent.
enum BoardFocusGraphBuilder {
    static func makeGraph(projection: BoardProjection, layout: BoardLayout) -> FocusGraph {
        var nodes: [FocusNode] = []
        var zoneEntryPoints: [SemanticFocusZone: SemanticFocusID] = [:]

        nodes.append(FocusNode(id: BoardFocusID.scenarioHeader, zone: BoardFocusZone.scenario))
        zoneEntryPoints[BoardFocusZone.scenario] = BoardFocusID.scenarioHeader

        // Ordered agendas-then-acts to match `BoardActAgendaColumnView`'s own rendering
        // order (agenda tiles above act tiles), so the zone's entry point and up/down
        // focus traversal always agree with what's actually on screen.
        let actAgendaChain = projection.agendas.map { BoardFocusID.agenda($0.id) }
            + projection.acts.map { BoardFocusID.act($0.id) }
        appendVerticalChain(
            actAgendaChain, zone: BoardFocusZone.actAgenda,
            nodes: &nodes, zoneEntryPoints: &zoneEntryPoints
        )

        appendLocations(
            projection.locations, layout: layout, nodes: &nodes, zoneEntryPoints: &zoneEntryPoints
        )

        let enemyLocationChain = projection.enemyLocations.map { BoardFocusID.enemyLocation($0.id) }
        appendHorizontalChain(
            enemyLocationChain, zone: BoardFocusZone.enemyLocations,
            nodes: &nodes, zoneEntryPoints: &zoneEntryPoints
        )

        let investigatorChain = projection.investigators.map { BoardFocusID.investigator($0.id) }
        appendHorizontalChain(
            investigatorChain, zone: BoardFocusZone.investigators,
            nodes: &nodes, zoneEntryPoints: &zoneEntryPoints
        )

        nodes.append(FocusNode(id: BoardFocusID.chaosBagSummary, zone: BoardFocusZone.chaosBag))
        zoneEntryPoints[BoardFocusZone.chaosBag] = BoardFocusID.chaosBagSummary

        return FocusGraph(
            nodes: nodes, zoneEntryPoints: zoneEntryPoints, wrapPolicy: .wrapWithinZone
        )
    }

    /// The zones that currently have at least one navigable node, in
    /// ``BoardFocusZone/cycleOrder``, for ``BoardCommandController``'s zone cycling. An
    /// empty optional zone (for example no acts/agendas at all) is simply skipped rather
    /// than cycled into and left with nothing to focus.
    static func nonEmptyZonesInCycleOrder(projection: BoardProjection) -> [SemanticFocusZone] {
        var populated: Set<SemanticFocusZone> = [BoardFocusZone.scenario, BoardFocusZone.chaosBag]
        if !projection.acts.isEmpty || !projection.agendas.isEmpty {
            populated.insert(BoardFocusZone.actAgenda)
        }
        if !projection.locations.isEmpty {
            populated.insert(BoardFocusZone.locations)
        }
        if !projection.enemyLocations.isEmpty {
            populated.insert(BoardFocusZone.enemyLocations)
        }
        if !projection.investigators.isEmpty {
            populated.insert(BoardFocusZone.investigators)
        }
        return BoardFocusZone.cycleOrder.filter { populated.contains($0) }
    }

    private static func appendVerticalChain(
        _ ids: [SemanticFocusID], zone: SemanticFocusZone,
        nodes: inout [FocusNode], zoneEntryPoints: inout [SemanticFocusZone: SemanticFocusID]
    ) {
        guard !ids.isEmpty else { return }
        for (index, id) in ids.enumerated() {
            var neighbors: [FocusDirection: SemanticFocusID] = [:]
            if index > 0 {
                neighbors[.up] = ids[index - 1]
            }
            if index < ids.count - 1 {
                neighbors[.down] = ids[index + 1]
            }
            nodes.append(FocusNode(id: id, zone: zone, neighbors: neighbors))
        }
        zoneEntryPoints[zone] = ids[0]
    }

    private static func appendHorizontalChain(
        _ ids: [SemanticFocusID], zone: SemanticFocusZone,
        nodes: inout [FocusNode], zoneEntryPoints: inout [SemanticFocusZone: SemanticFocusID]
    ) {
        guard !ids.isEmpty else { return }
        for (index, id) in ids.enumerated() {
            var neighbors: [FocusDirection: SemanticFocusID] = [:]
            if index > 0 {
                neighbors[.left] = ids[index - 1]
            }
            if index < ids.count - 1 {
                neighbors[.right] = ids[index + 1]
            }
            nodes.append(FocusNode(id: id, zone: zone, neighbors: neighbors))
        }
        zoneEntryPoints[zone] = ids[0]
    }

    private static func appendLocations(
        _ locations: [BoardLocationNode], layout: BoardLayout,
        nodes: inout [FocusNode], zoneEntryPoints: inout [SemanticFocusZone: SemanticFocusID]
    ) {
        guard !locations.isEmpty else { return }
        for location in locations {
            var neighbors: [FocusDirection: SemanticFocusID] = [:]
            for (direction, neighborID) in layout.neighbors[location.id] ?? [:] {
                neighbors[direction] = BoardFocusID.location(neighborID)
            }
            nodes.append(
                FocusNode(
                    id: BoardFocusID.location(location.id), zone: BoardFocusZone.locations,
                    neighbors: neighbors
                )
            )
        }
        // The entry point is whichever location BFS layering placed first (column 0, row
        // 0), matching the layout's own deterministic root — falling back to the first
        // projection-ordered location if, for any reason, layout has no positions at all.
        let rootID = layout.positions
            .first { $0.value == BoardGridPosition(column: 0, row: 0) }?.key ?? locations[0].id
        zoneEntryPoints[BoardFocusZone.locations] = BoardFocusID.location(rootID)
    }
}
