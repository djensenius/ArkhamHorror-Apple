import Foundation

/// Builds a deterministic ``BoardProjection`` from a decoded ``PublicGameSnapshot``.
///
/// This is the sole place that reads the raw snapshot's `Dictionary`-backed maps
/// (`UUIDKeyedMap`/plain `[Key: Value]`) and turns them into stably-ordered arrays: every
/// sort key here is a plain value (`UUID` text, `Int`, or `CardCode` text) compared with
/// `String`/`Int`'s own `<` operator, never `Dictionary` iteration order and never a
/// locale-sensitive comparison. Two snapshots with equal field values always build to an
/// equal ``BoardProjection`` regardless of map insertion order.
enum BoardProjectionBuilder {
    static func makeProjection(from snapshot: PublicGameSnapshot) -> BoardProjection {
        let (hasCampaignContext, scenario) = makeScenario(from: snapshot.mode)
        let (locations, enemyLocations) = makeLocations(from: snapshot.locations)
        let investigatorLocations = makeInvestigatorLocationLookup(
            locations: locations, enemyLocations: enemyLocations
        )
        let investigators = makeInvestigators(
            from: snapshot, currentLocations: investigatorLocations
        )
        return BoardProjection(
            gameName: BoardDisplayFormatting.safeLabel(
                snapshot.name, fallback: snapshot.id.description
            ),
            hasCampaignContext: hasCampaignContext,
            scenario: scenario,
            acts: makeActs(from: snapshot.acts),
            agendas: makeAgendas(from: snapshot.agendas),
            locations: locations,
            enemyLocations: enemyLocations,
            investigators: investigators,
            otherInvestigatorCount: snapshot.otherInvestigators.count,
            killedInvestigatorCount: snapshot.killedInvestigators.count,
            chaosBag: makeChaosBag(from: snapshot.mode),
            counters: makeCounters(from: snapshot),
            questions: snapshot.question
        )
    }

    // MARK: - Scenario / campaign

    private static func makeScenario(
        from mode: GameMode
    ) -> (hasCampaignContext: Bool, scenario: BoardScenarioSummary?) {
        switch mode {
        case .campaignOnly:
            (true, nil)
        case let .scenarioOnly(scenario):
            (false, makeScenarioSummary(scenario))
        case let .campaignAndScenario(_, scenario):
            (true, makeScenarioSummary(scenario))
        }
    }

    private static func makeScenarioSummary(_ scenario: Scenario) -> BoardScenarioSummary {
        BoardScenarioSummary(
            displayName: BoardDisplayFormatting.safeTitle(
                scenario.name, fallback: scenario.id.description
            ),
            subtitle: BoardDisplayFormatting.safeSubtitle(scenario.name),
            difficulty: scenario.difficulty,
            turn: scenario.turn,
            reference: scenario.reference,
            usesGrid: scenario.usesGrid,
            isPrelude: scenario.isPrelude,
            isSideStory: scenario.isSideStory,
            inResolution: scenario.inResolution,
            started: scenario.started
        )
    }

    private static func makeChaosBag(from mode: GameMode) -> BoardChaosBagState {
        let scenario: Scenario? = switch mode {
        case .campaignOnly: nil
        case let .scenarioOnly(scenario): scenario
        case let .campaignAndScenario(_, scenario): scenario
        }
        guard let scenario else {
            return .noActiveScenario
        }
        let bag = scenario.chaosBag
        return .scenario(BoardChaosBagSummary(
            poolCounts: BoardDisplayFormatting.groupChaosFaceCounts(bag.chaosTokens),
            revealedCounts: BoardDisplayFormatting.groupChaosFaceCounts(bag.revealedChaosTokens),
            setAsideCounts: BoardDisplayFormatting.groupChaosFaceCounts(bag.setAsideChaosTokens),
            forceDrawFace: bag.forceDraw,
            hasPendingChoice: bag.choice != nil
        ))
    }

    // MARK: - Counters

    private static func makeCounters(from snapshot: PublicGameSnapshot) -> BoardCounters {
        BoardCounters(
            totalDoom: snapshot.totalDoom,
            totalClues: snapshot.totalClues,
            encounterDeckSize: snapshot.encounterDeckSize,
            scenarioSteps: snapshot.scenarioSteps,
            playerCount: snapshot.playerCount,
            phase: snapshot.phase,
            phaseStepSummary: BoardDisplayFormatting.phaseStepSummary(snapshot.phaseStep),
            gameStateSummary: BoardDisplayFormatting.gameStateSummary(snapshot.gameState),
            inSetup: snapshot.inSetup,
            inAction: snapshot.inAction,
            pendingPromptCount: snapshot.question.count,
            entityCounters: BoardEntityCounters(
                enemies: snapshot.enemies.count,
                assets: snapshot.assets.count,
                treacheries: snapshot.treacheries.count,
                events: snapshot.events.count,
                skills: snapshot.skills.count,
                concealed: snapshot.concealed.count,
                cards: snapshot.cards.count
            )
        )
    }
}
