import Foundation

extension BoardFocusGraphBuilder {
    // swiftlint:disable:next function_parameter_count
    static func appendLocations(
        _ locations: [BoardLocationNode],
        enemiesByLocationID: [LocationID: [BoardEnemyNode]],
        choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]],
        layout: BoardLayout,
        nodes: inout [FocusNode], zoneEntryPoints: inout [SemanticFocusZone: SemanticFocusID]
    ) {
        guard !locations.isEmpty else { return }
        let actionIDs = locationEnemyActionIDs(
            locations,
            enemiesByLocationID: enemiesByLocationID,
            choiceLinks: choiceLinks
        )
        let reciprocalUpTargets = originalDownNeighborActionIDs(
            locations: locations,
            layout: layout,
            actionIDs: actionIDs
        )
        for location in locations {
            let layoutNeighbors = layout.neighbors[location.id] ?? [:]
            let actionID = actionIDs[location.id]
            nodes.append(FocusNode(
                id: BoardFocusID.location(location.id),
                zone: BoardFocusZone.locations,
                neighbors: locationNeighbors(
                    layoutNeighbors,
                    actionID: actionID,
                    reciprocalUpTarget: reciprocalUpTargets[location.id]
                )
            ))
            if let actionID {
                nodes.append(FocusNode(
                    id: actionID,
                    zone: BoardFocusZone.locations,
                    neighbors: locationEnemyActionNeighbors(
                        locationID: location.id,
                        layoutNeighbors: layoutNeighbors
                    )
                ))
            }
        }
        // The entry point is whichever location BFS layering placed first (column 0, row
        // 0), matching the layout's own deterministic root — falling back to the first
        // projection-ordered location if, for any reason, layout has no positions at all.
        let rootID = layout.positions
            .first { $0.value == BoardGridPosition(column: 0, row: 0) }?.key ?? locations[0].id
        zoneEntryPoints[BoardFocusZone.locations] = BoardFocusID.location(rootID)
    }

    private static func locationEnemyActionIDs(
        _ locations: [BoardLocationNode],
        enemiesByLocationID: [LocationID: [BoardEnemyNode]],
        choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    ) -> [LocationID: SemanticFocusID] {
        Dictionary(uniqueKeysWithValues: locations.compactMap { location in
            linkedEnemyActionsFocusID(
                locationID: location.id,
                enemies: enemiesByLocationID[location.id] ?? [],
                choiceLinks: choiceLinks,
                makeFocusID: BoardFocusID.locationEnemyActions
            ).map { (location.id, $0) }
        })
    }

    private static func originalDownNeighborActionIDs(
        locations: [BoardLocationNode],
        layout: BoardLayout,
        actionIDs: [LocationID: SemanticFocusID]
    ) -> [LocationID: SemanticFocusID] {
        Dictionary(
            locations.compactMap { location in
                guard let actionID = actionIDs[location.id],
                      let downNeighbor = layout.neighbors[location.id]?[.down]
                else { return nil }
                return (downNeighbor, actionID)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func locationNeighbors(
        _ layoutNeighbors: [FocusDirection: LocationID],
        actionID: SemanticFocusID?,
        reciprocalUpTarget: SemanticFocusID?
    ) -> [FocusDirection: SemanticFocusID] {
        var neighbors = Dictionary(uniqueKeysWithValues: layoutNeighbors.map {
            ($0.key, BoardFocusID.location($0.value))
        })
        if let actionID {
            neighbors[.down] = actionID
        }
        if let reciprocalUpTarget {
            neighbors[.up] = reciprocalUpTarget
        }
        return neighbors
    }

    private static func locationEnemyActionNeighbors(
        locationID: LocationID,
        layoutNeighbors: [FocusDirection: LocationID]
    ) -> [FocusDirection: SemanticFocusID] {
        var neighbors: [FocusDirection: SemanticFocusID] = [
            .up: BoardFocusID.location(locationID),
        ]
        for direction in [FocusDirection.down, .left, .right] {
            if let neighborID = layoutNeighbors[direction] {
                neighbors[direction] = BoardFocusID.location(neighborID)
            }
        }
        return neighbors
    }

    static func enemyLocationFocusIDs(
        _ enemyLocations: [BoardEnemyLocationNode],
        enemiesByLocationID: [LocationID: [BoardEnemyNode]],
        choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    ) -> [SemanticFocusID] {
        enemyLocations.flatMap { location in
            var ids = [BoardFocusID.enemyLocation(location.id)]
            if let actionsID = linkedEnemyActionsFocusID(
                locationID: location.id,
                enemies: enemiesByLocationID[location.id] ?? [],
                choiceLinks: choiceLinks,
                makeFocusID: BoardFocusID.enemyLocationEnemyActions
            ) {
                ids.append(actionsID)
            }
            return ids
        }
    }

    static func investigatorFocusIDs(
        projection: BoardProjection,
        choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]],
        fullPlayerAreaPlayerID: PlayerID?
    ) -> [SemanticFocusID] {
        projection.investigators.flatMap { investigator in
            var ids = [BoardFocusID.investigator(investigator.id)]
            let showsFullArea = BoardPlayerAreaVisibility.shouldShowFullArea(
                for: investigator,
                fullPlayerAreaPlayerID: fullPlayerAreaPlayerID
            )
            if showsFullArea {
                ids += promptElementIDs(
                    for: projection.orderedHandCardsByPlayer[investigator.playerID] ?? [],
                    choiceLinks: choiceLinks
                )
                ids += promptElementIDs(
                    for: projection.inPlayCardsByPlayer[investigator.playerID] ?? [],
                    choiceLinks: choiceLinks
                )
            }
            ids += promptElementIDs(
                for: projection.engagedEnemiesByInvestigatorID[investigator.id] ?? [],
                choiceLinks: choiceLinks
            )
            ids += promptElementIDs(
                for: projection.threatTreacheriesByPlayer[investigator.playerID] ?? [],
                choiceLinks: choiceLinks
            )
            return ids
        }
    }

    static func linkedEnemyChoices(
        for enemies: [BoardEnemyNode],
        choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    ) -> [BoardLinkedChoice] {
        enemies.flatMap { choiceLinks[.enemy($0.id)] ?? [] }
    }

    private static func linkedEnemyActionsFocusID(
        locationID: LocationID,
        enemies: [BoardEnemyNode],
        choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]],
        makeFocusID: (LocationID) -> SemanticFocusID
    ) -> SemanticFocusID? {
        let linkedChoices = linkedEnemyChoices(for: enemies, choiceLinks: choiceLinks)
        switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
        case .submit, .menu:
            return makeFocusID(locationID)
        case .highlightOnly:
            return nil
        }
    }

    private static func promptElementIDs(
        for cards: [BoardPlayerCardNode],
        choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    ) -> [SemanticFocusID] {
        cards.compactMap { card in
            let elementID = BoardPromptElementID.playerCard(card.id)
            return isFocusablePromptElement(elementID, choiceLinks: choiceLinks)
                ? BoardFocusID.promptElement(elementID)
                : nil
        }
    }

    private static func promptElementIDs(
        for enemies: [BoardEnemyNode],
        choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    ) -> [SemanticFocusID] {
        enemies.compactMap { enemy in
            let elementID = BoardPromptElementID.enemy(enemy.id)
            return isFocusablePromptElement(elementID, choiceLinks: choiceLinks)
                ? BoardFocusID.promptElement(elementID)
                : nil
        }
    }

    private static func promptElementIDs(
        for treacheries: [BoardThreatTreacheryNode],
        choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    ) -> [SemanticFocusID] {
        treacheries.compactMap { treachery in
            let elementID = BoardPromptElementID.treachery(treachery.id)
            return isFocusablePromptElement(elementID, choiceLinks: choiceLinks)
                ? BoardFocusID.promptElement(elementID)
                : nil
        }
    }

    private static func isFocusablePromptElement(
        _ elementID: BoardPromptElementID,
        choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    ) -> Bool {
        guard let linkedChoices = choiceLinks[elementID] else { return false }
        switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
        case .submit, .menu:
            return true
        case .highlightOnly:
            return false
        }
    }
}
