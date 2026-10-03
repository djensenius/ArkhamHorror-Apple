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
        for location in locations {
            let linkedEnemyActionsID = linkedEnemyActionsFocusID(
                locationID: location.id,
                enemies: enemiesByLocationID[location.id] ?? [],
                choiceLinks: choiceLinks,
                makeFocusID: BoardFocusID.locationEnemyActions
            )
            var neighbors: [FocusDirection: SemanticFocusID] = [:]
            for (direction, neighborID) in layout.neighbors[location.id] ?? [:] {
                neighbors[direction] = BoardFocusID.location(neighborID)
            }
            let originalDownNeighbor = neighbors[.down]
            if let linkedEnemyActionsID {
                neighbors[.down] = linkedEnemyActionsID
            }
            nodes.append(
                FocusNode(
                    id: BoardFocusID.location(location.id), zone: BoardFocusZone.locations,
                    neighbors: neighbors
                )
            )
            if let linkedEnemyActionsID {
                var actionNeighbors: [FocusDirection: SemanticFocusID] = [
                    .up: BoardFocusID.location(location.id),
                ]
                if let originalDownNeighbor {
                    actionNeighbors[.down] = originalDownNeighbor
                }
                nodes.append(FocusNode(
                    id: linkedEnemyActionsID,
                    zone: BoardFocusZone.locations,
                    neighbors: actionNeighbors
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
