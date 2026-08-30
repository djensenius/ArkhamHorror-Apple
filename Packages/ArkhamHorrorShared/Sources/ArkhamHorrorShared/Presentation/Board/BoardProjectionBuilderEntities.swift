/// Act/agenda/location/investigator entity-building helpers for
/// ``BoardProjectionBuilder``, split into this extension purely to stay under SwiftLint's
/// type-body-length budget for the primary declaration.
extension BoardProjectionBuilder {
    // MARK: - Acts / agendas

    static func makeActs(from acts: [ActID: Act]) -> [BoardActNode] {
        acts.values
            .map { act in
                BoardActNode(
                    id: act.id,
                    cardCode: act.id.rawValue,
                    deckID: act.deckID,
                    sequence: act.sequence,
                    flipped: act.flipped,
                    advanceCostSummary: act.advanceCost.map(
                        BoardDisplayFormatting.runtimeCostSummary
                    ),
                    tokenCounts: BoardDisplayFormatting.groupTokenCounts(act.tokens),
                    treacheryCount: act.treacheries.count,
                    cardsUnderneathCount: act.cardsUnderneath.count
                )
            }
            .sorted(by: actSortKey)
    }

    static func actSortKey(_ lhs: BoardActNode, _ rhs: BoardActNode) -> Bool {
        if lhs.deckID != rhs.deckID {
            return lhs.deckID < rhs.deckID
        }
        if lhs.sequence.step != rhs.sequence.step {
            return lhs.sequence.step < rhs.sequence.step
        }
        if lhs.sequence.side != rhs.sequence.side {
            return lhs.sequence.side.rawValue < rhs.sequence.side.rawValue
        }
        return lhs.cardCode.rawValue < rhs.cardCode.rawValue
    }

    static func makeAgendas(from agendas: [AgendaID: Agenda]) -> [BoardAgendaNode] {
        agendas.values
            .map { agenda in
                BoardAgendaNode(
                    id: agenda.id,
                    cardCode: agenda.id.rawValue,
                    deckID: agenda.deckID,
                    sequence: agenda.sequence,
                    doom: agenda.doom,
                    doomThresholdSummary: agenda.doomThreshold.map(
                        BoardDisplayFormatting.gameValueSummary
                    ),
                    flipped: agenda.flipped,
                    tokenCounts: BoardDisplayFormatting.groupTokenCounts(agenda.tokens),
                    treacheryCount: agenda.treacheries.count,
                    cardsUnderneathCount: agenda.cardsUnderneath.count
                )
            }
            .sorted(by: agendaSortKey)
    }

    static func agendaSortKey(_ lhs: BoardAgendaNode, _ rhs: BoardAgendaNode) -> Bool {
        if lhs.deckID != rhs.deckID {
            return lhs.deckID < rhs.deckID
        }
        if lhs.sequence.step != rhs.sequence.step {
            return lhs.sequence.step < rhs.sequence.step
        }
        if lhs.sequence.side != rhs.sequence.side {
            return lhs.sequence.side.rawValue < rhs.sequence.side.rawValue
        }
        return lhs.cardCode.rawValue < rhs.cardCode.rawValue
    }

    // MARK: - Locations

    static func makeLocations(
        from locations: UUIDKeyedMap<LocationIDTag, Location>
    ) -> (ordinary: [BoardLocationNode], enemy: [BoardEnemyLocationNode]) {
        var ordinary: [BoardLocationNode] = []
        var enemy: [BoardEnemyLocationNode] = []
        for (_, location) in locations {
            switch location {
            case let .ordinary(value):
                ordinary.append(makeLocationNode(value))
            case let .enemy(value):
                enemy.append(makeEnemyLocationNode(value))
            }
        }
        ordinary.sort { $0.id.description < $1.id.description }
        enemy.sort { $0.id.description < $1.id.description }
        return (ordinary, enemy)
    }

    static func makeLocationNode(_ location: OrdinaryLocation) -> BoardLocationNode {
        let tokens = BoardDisplayFormatting.groupTokenCounts(location.tokens)
        return BoardLocationNode(
            id: location.id,
            cardCode: location.cardCode,
            displayLabel: BoardDisplayFormatting.safeLabel(
                location.label, fallback: location.cardCode.rawValue
            ),
            revealed: location.revealed,
            symbol: location.revealed ? location.revealedSymbol : location.symbol,
            shroudSummary: location.shroud.map(BoardDisplayFormatting.gameValueSummary),
            investigateSkill: location.investigateSkill,
            clueCount: tokens.first { $0.token == "Clue" }?.count ?? 0,
            doomCount: tokens.first { $0.token == "Doom" }?.count ?? 0,
            otherTokenCounts: tokens.filter { $0.token != "Clue" && $0.token != "Doom" },
            investigatorIDs: location.investigators,
            enemyCount: location.enemies.count,
            assetCount: location.assets.count,
            eventCount: location.events.count,
            treacheryCount: location.treacheries.count,
            concealedCount: location.concealedCards.count,
            connectedLocationIDs: location.connectedLocations
                .sorted { $0.description < $1.description },
            placementSummary: location.placement.map(BoardDisplayFormatting.placementSummary)
        )
    }

    static func makeEnemyLocationNode(
        _ location: EnemyLocationView
    ) -> BoardEnemyLocationNode {
        BoardEnemyLocationNode(
            id: location.id,
            cardCode: location.cardCode,
            displayLabel: BoardDisplayFormatting.safeLabel(
                location.label, fallback: location.cardCode.rawValue
            ),
            revealed: location.revealed,
            exhausted: location.exhausted,
            shroudSummary: location.shroud.map(BoardDisplayFormatting.gameValueSummary),
            tokenCounts: BoardDisplayFormatting.groupTokenCounts(location.tokens),
            investigatorIDs: location.investigators,
            enemyCount: location.enemies.count,
            assetCount: location.assets.count,
            eventCount: location.events.count,
            treacheryCount: location.treacheries.count,
            concealedCount: location.concealedCards.count,
            connectedLocationIDs: location.connectedLocations
                .sorted { $0.description < $1.description }
        )
    }

    /// A single pass over every location's own `investigators` array, producing a reverse
    /// lookup from investigator to current location — never a per-investigator scan over
    /// every location (which would be quadratic in investigator/location count).
    static func makeInvestigatorLocationLookup(
        locations: [BoardLocationNode], enemyLocations: [BoardEnemyLocationNode]
    ) -> [InvestigatorID: LocationID] {
        var result: [InvestigatorID: LocationID] = [:]
        for location in locations {
            for investigatorID in location.investigatorIDs {
                result[investigatorID] = location.id
            }
        }
        for location in enemyLocations {
            for investigatorID in location.investigatorIDs {
                result[investigatorID] = location.id
            }
        }
        return result
    }

    // MARK: - Investigators

    static func makeInvestigators(
        from snapshot: PublicGameSnapshot, currentLocations: [InvestigatorID: LocationID]
    ) -> [BoardInvestigatorNode] {
        var orderedIDs = snapshot.playerOrder
        let orderedSet = Set(orderedIDs)
        let remaining = snapshot.investigators.keys
            .filter { !orderedSet.contains($0) }
            .sorted { $0.rawValue.rawValue < $1.rawValue.rawValue }
        orderedIDs.append(contentsOf: remaining)

        return orderedIDs.compactMap { id in
            guard let investigator = snapshot.investigators[id] else { return nil }
            return makeInvestigatorNode(
                investigator,
                currentLocation: currentLocations[id],
                activeInvestigatorID: snapshot.activeInvestigatorID,
                turnPlayerInvestigatorID: snapshot.turnPlayerInvestigatorID,
                leadInvestigatorID: snapshot.leadInvestigatorID
            )
        }
    }

    static func makeInvestigatorNode(
        _ investigator: Investigator,
        currentLocation: LocationID?,
        activeInvestigatorID: InvestigatorID,
        turnPlayerInvestigatorID: InvestigatorID?,
        leadInvestigatorID: InvestigatorID
    ) -> BoardInvestigatorNode {
        BoardInvestigatorNode(
            id: investigator.id,
            displayName: BoardDisplayFormatting.safeTitle(
                investigator.name, fallback: investigator.cardCode.rawValue
            ),
            subtitle: BoardDisplayFormatting.safeSubtitle(investigator.name),
            investigatorClass: investigator.investigatorClass,
            health: investigator.health,
            sanity: investigator.sanity,
            remainingActions: investigator.remainingActions,
            physicalTrauma: investigator.physicalTrauma,
            mentalTrauma: investigator.mentalTrauma,
            unhealedHorrorThisRound: investigator.unhealedHorrorThisRound,
            assignedHealthDamage: investigator.assignedHealthDamage,
            assignedSanityDamage: investigator.assignedSanityDamage,
            defeated: investigator.defeated,
            resigned: investigator.resigned,
            eliminated: investigator.eliminated,
            drivenInsane: investigator.drivenInsane,
            currentLocationID: currentLocation,
            isActiveInvestigator: investigator.id == activeInvestigatorID,
            isTurnPlayer: investigator.id == turnPlayerInvestigatorID,
            isLeadInvestigator: investigator.id == leadInvestigatorID,
            engagedEnemyCount: investigator.engagedEnemies.count,
            assetCount: investigator.assets.count,
            eventCount: investigator.events.count,
            treacheryCount: investigator.treacheries.count,
            skillCount: investigator.skills.count,
            scarletKeyCount: investigator.scarletKeys.count,
            tokenCounts: BoardDisplayFormatting.groupTokenCounts(investigator.tokens),
            movementSummary: investigator.movement.map(BoardDisplayFormatting.movementSummary),
            placementSummary: BoardDisplayFormatting.placementSummary(investigator.placement)
        )
    }
}
