import Foundation

private extension FocusDirection {
    var boardOpposite: FocusDirection {
        switch self {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
    }
}

private struct LocationEnemyActionEdgePlan {
    var forwardTargets: [LocationID: [FocusDirection: SemanticFocusID]] = [:]
    var reverseTargets: [LocationID: [FocusDirection: SemanticFocusID]] = [:]
}

extension BoardFocusGraphBuilder {
    // swiftlint:disable:next function_body_length function_parameter_count
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
        let headerFallbackTargets = locationHeaderFallbackTargets(locations)
        let headerBaseTargets = locationHeaderBaseTargets(
            locations: locations,
            layout: layout,
            headerFallbackTargets: headerFallbackTargets
        )
        let actionEdgePlan = locationEnemyActionEdgePlan(
            locations: locations,
            layout: layout,
            actionIDs: actionIDs,
            headerBaseTargets: headerBaseTargets
        )
        // The entry point is whichever location BFS layering placed first (column 0, row
        // 0), matching the layout's own deterministic root — falling back to the first
        // projection-ordered location if, for any reason, layout has no positions at all.
        let rootID = layout.positions
            .first { $0.value == BoardGridPosition(column: 0, row: 0) }?.key ?? locations[0].id
        var headerNeighbors: [LocationID: [FocusDirection: SemanticFocusID]] = [:]
        var actionNeighbors: [LocationID: [FocusDirection: SemanticFocusID]] = [:]
        for location in locations {
            let layoutNeighbors = layout.neighbors[location.id] ?? [:]
            let actionID = actionIDs[location.id]
            headerNeighbors[location.id] = locationNeighbors(
                layoutNeighbors,
                headerFallbackTargets: headerFallbackTargets[location.id] ?? [:],
                actionID: actionID,
                reciprocalTargets: actionEdgePlan.reverseTargets[location.id] ?? [:]
            )
            if actionID != nil {
                actionNeighbors[location.id] = locationEnemyActionNeighbors(
                    locationID: location.id,
                    plannedTargets: actionEdgePlan.forwardTargets[location.id] ?? [:]
                )
            }
        }
        repairLocationHeaderReachability(
            locations: locations,
            rootID: rootID,
            headerNeighbors: &headerNeighbors,
            actionNeighbors: actionNeighbors
        )
        for location in locations {
            nodes.append(FocusNode(
                id: BoardFocusID.location(location.id),
                zone: BoardFocusZone.locations,
                neighbors: headerNeighbors[location.id] ?? [:]
            ))
            if let actionID = actionIDs[location.id] {
                nodes.append(FocusNode(
                    id: actionID,
                    zone: BoardFocusZone.locations,
                    neighbors: actionNeighbors[location.id] ?? [:]
                ))
            }
        }
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

    private static func locationHeaderFallbackTargets(
        _ locations: [BoardLocationNode]
    ) -> [LocationID: [FocusDirection: LocationID]] {
        guard locations.count > 1 else { return [:] }
        var targets: [LocationID: [FocusDirection: LocationID]] = [:]
        for (index, location) in locations.enumerated() {
            let previous = locations[(index - 1 + locations.count) % locations.count]
            let next = locations[(index + 1) % locations.count]
            targets[location.id] = [
                .up: previous.id,
                .left: previous.id,
                .down: next.id,
                .right: next.id,
            ]
        }
        return targets
    }

    private static func locationHeaderBaseTargets(
        locations: [BoardLocationNode],
        layout: BoardLayout,
        headerFallbackTargets: [LocationID: [FocusDirection: LocationID]]
    ) -> [LocationID: [FocusDirection: LocationID]] {
        Dictionary(uniqueKeysWithValues: locations.map { location in
            var targets = headerFallbackTargets[location.id] ?? [:]
            for (direction, neighborID) in layout.neighbors[location.id] ?? [:] {
                targets[direction] = neighborID
            }
            return (location.id, targets)
        })
    }

    private static func locationEnemyActionEdgePlan(
        locations: [BoardLocationNode],
        layout: BoardLayout,
        actionIDs: [LocationID: SemanticFocusID],
        headerBaseTargets: [LocationID: [FocusDirection: LocationID]]
    ) -> LocationEnemyActionEdgePlan {
        let headerFallbackTargets = locationHeaderFallbackTargets(locations)
        var plan = LocationEnemyActionEdgePlan()
        for location in locations {
            guard let actionID = actionIDs[location.id] else { continue }
            let layoutNeighbors = layout.neighbors[location.id] ?? [:]
            for direction in [FocusDirection.down, .left, .right] {
                if let neighborID = layoutNeighbors[direction] {
                    planRealLayoutActionEdge(
                        from: location.id, actionID: actionID, direction: direction,
                        neighborID: neighborID, headerBaseTargets: headerBaseTargets, plan: &plan
                    )
                } else if let fallbackID = headerFallbackTargets[location.id]?[direction] {
                    planHeaderFallbackActionEdge(
                        actionLocationID: location.id, actionID: actionID, direction: direction,
                        fallbackID: fallbackID, layout: layout, plan: &plan
                    )
                } else {
                    plan.forwardTargets[location.id, default: [:]][direction] = actionID
                }
            }
        }
        return plan
    }

    // swiftlint:disable:next function_parameter_count
    private static func planRealLayoutActionEdge(
        from locationID: LocationID,
        actionID: SemanticFocusID,
        direction: FocusDirection,
        neighborID: LocationID,
        headerBaseTargets: [LocationID: [FocusDirection: LocationID]],
        plan: inout LocationEnemyActionEdgePlan
    ) {
        let reverse = direction.boardOpposite
        let isReciprocalHeaderEdge = headerBaseTargets[neighborID]?[reverse] == locationID
        guard isReciprocalHeaderEdge else {
            // Another location/action may already own this neighbor's reverse slot. In that
            // case keep the action's forward edge on the header-only target, but do not
            // replace the neighbor's unrelated return edge.
            plan.forwardTargets[locationID, default: [:]][direction] = BoardFocusID.location(
                neighborID
            )
            return
        }
        assert(
            plan.reverseTargets[neighborID]?[reverse] == nil,
            "Reciprocal layout action claims are unique because the header-only reverse edge "
                + "can point at only one location."
        )
        plan.forwardTargets[locationID, default: [:]][direction] = BoardFocusID.location(
            neighborID
        )
        plan.reverseTargets[neighborID, default: [:]][reverse] = actionID
    }

    // swiftlint:disable:next function_parameter_count
    private static func planHeaderFallbackActionEdge(
        actionLocationID: LocationID,
        actionID: SemanticFocusID,
        direction: FocusDirection,
        fallbackID: LocationID,
        layout: BoardLayout,
        plan: inout LocationEnemyActionEdgePlan
    ) {
        let reverse = direction.boardOpposite
        plan.forwardTargets[actionLocationID, default: [:]][direction] = BoardFocusID.location(
            fallbackID
        )
        guard (layout.neighbors[fallbackID] ?? [:])[reverse] == nil else { return }
        assert(
            plan.reverseTargets[fallbackID]?[reverse] == nil,
            "Fallback action claims are unique because each fallback reverse slot has one "
                + "header-only predecessor."
        )
        plan.reverseTargets[fallbackID, default: [:]][reverse] = actionID
    }

    private static func locationNeighbors(
        _ layoutNeighbors: [FocusDirection: LocationID],
        headerFallbackTargets: [FocusDirection: LocationID],
        actionID: SemanticFocusID?,
        reciprocalTargets: [FocusDirection: SemanticFocusID]
    ) -> [FocusDirection: SemanticFocusID] {
        var neighbors = Dictionary(uniqueKeysWithValues: headerFallbackTargets.map {
            ($0.key, BoardFocusID.location($0.value))
        })
        for (direction, locationID) in layoutNeighbors {
            neighbors[direction] = BoardFocusID.location(locationID)
        }
        if let actionID {
            neighbors[.down] = actionID
        }
        for (direction, reciprocalTarget) in reciprocalTargets {
            neighbors[direction] = reciprocalTarget
        }
        return neighbors
    }

    private static func locationEnemyActionNeighbors(
        locationID: LocationID,
        plannedTargets: [FocusDirection: SemanticFocusID]
    ) -> [FocusDirection: SemanticFocusID] {
        var neighbors: [FocusDirection: SemanticFocusID] = [
            .up: BoardFocusID.location(locationID),
        ]
        for (direction, target) in plannedTargets {
            neighbors[direction] = target
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
