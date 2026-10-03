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
            let linkedEnemyIDs = promptElementIDs(
                for: enemiesByLocationID[location.id] ?? [],
                choiceLinks: choiceLinks
            )
            var neighbors: [FocusDirection: SemanticFocusID] = [:]
            for (direction, neighborID) in layout.neighbors[location.id] ?? [:] {
                neighbors[direction] = BoardFocusID.location(neighborID)
            }
            if neighbors[.down] == nil, let firstEnemy = linkedEnemyIDs.first {
                neighbors[.down] = firstEnemy
            }
            nodes.append(
                FocusNode(
                    id: BoardFocusID.location(location.id), zone: BoardFocusZone.locations,
                    neighbors: neighbors
                )
            )
            appendLinkedElementVerticalChain(
                linkedEnemyIDs,
                previousID: BoardFocusID.location(location.id),
                zone: BoardFocusZone.locations,
                nodes: &nodes
            )
        }
        // The entry point is whichever location BFS layering placed first (column 0, row
        // 0), matching the layout's own deterministic root — falling back to the first
        // projection-ordered location if, for any reason, layout has no positions at all.
        let rootID = layout.positions
            .first { $0.value == BoardGridPosition(column: 0, row: 0) }?.key ?? locations[0].id
        zoneEntryPoints[BoardFocusZone.locations] = BoardFocusID.location(rootID)
    }

    private static func appendLinkedElementVerticalChain(
        _ ids: [SemanticFocusID],
        previousID: SemanticFocusID,
        zone: SemanticFocusZone,
        nodes: inout [FocusNode]
    ) {
        for (index, id) in ids.enumerated() {
            let previous = index == 0 ? previousID : ids[index - 1]
            var neighbors: [FocusDirection: SemanticFocusID] = [.up: previous]
            if index < ids.count - 1 {
                neighbors[.down] = ids[index + 1]
            }
            nodes.append(FocusNode(id: id, zone: zone, neighbors: neighbors))
        }
    }

    static func enemyLocationFocusIDs(
        _ enemyLocations: [BoardEnemyLocationNode],
        enemiesByLocationID: [LocationID: [BoardEnemyNode]],
        choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    ) -> [SemanticFocusID] {
        enemyLocations.flatMap { location in
            [BoardFocusID.enemyLocation(location.id)]
                + promptElementIDs(
                    for: enemiesByLocationID[location.id] ?? [],
                    choiceLinks: choiceLinks
                )
        }
    }

    static func investigatorFocusIDs(
        projection: BoardProjection,
        choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]],
        fullPlayerAreaPlayerID: PlayerID?
    ) -> [SemanticFocusID] {
        let activeInvestigatorID = projection.investigators.first(where: \.isActiveInvestigator)?.id
        return projection.investigators.flatMap { investigator in
            var ids = [BoardFocusID.investigator(investigator.id)]
            let showsFullArea = BoardPlayerAreaVisibility.shouldShowFullArea(
                for: investigator,
                fullPlayerAreaPlayerID: fullPlayerAreaPlayerID
            )
            if showsFullArea || investigator.id == activeInvestigatorID {
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
