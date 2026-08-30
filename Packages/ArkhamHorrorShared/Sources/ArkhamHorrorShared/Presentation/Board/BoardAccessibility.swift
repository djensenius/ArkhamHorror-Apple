import Foundation

/// Pure VoiceOver/accessibility summary text for every board entity kind, factored out
/// from the SwiftUI views so it is directly unit-testable without instantiating any view.
/// Every summary is a plain, human-readable sentence — never raw JSON or a wire tag alone
/// — and every count/value comes straight from ``BoardProjection`` fields with no
/// additional inference.
enum BoardAccessibility {
    static func summary(scenario: BoardScenarioSummary?, hasCampaignContext: Bool) -> String {
        guard let scenario else {
            return hasCampaignContext
                ? "Campaign summary. \(BoardDisplayFormatting.unsupportedContentNotice)"
                : "No active scenario"
        }
        var parts = [
            "\(scenario.displayName), difficulty \(scenario.difficulty.rawValue), "
                + "turn \(scenario.turn)",
        ]
        if let subtitle = scenario.subtitle {
            parts.append(subtitle)
        }
        if scenario.isPrelude {
            parts.append("Prelude")
        }
        if scenario.isSideStory {
            parts.append("Side story")
        }
        if scenario.inResolution {
            parts.append("In resolution")
        }
        if !scenario.started {
            parts.append("Not yet started")
        }
        return parts.joined(separator: ". ")
    }

    static func summary(counters: BoardCounters) -> String {
        var parts = ["Phase \(BoardDisplayFormatting.humanizeTag(counters.phase.rawValue))"]
        if let step = counters.phaseStepSummary {
            parts.append(step)
        }
        parts.append("Game \(counters.gameStateSummary)")
        let cluesPhrase = BoardDisplayFormatting.pluralized(
            counters.totalClues, singular: "total clue", plural: "total clues"
        )
        parts.append("\(cluesPhrase), \(counters.totalDoom) total doom")
        let encounterDeckPhrase = BoardDisplayFormatting.pluralized(
            counters.encounterDeckSize, singular: "card", plural: "cards"
        )
        parts.append("Encounter deck \(encounterDeckPhrase)")
        if counters.pendingPromptCount > 0 {
            let promptPhrase = BoardDisplayFormatting.pluralized(
                counters.pendingPromptCount, singular: "pending prompt", plural: "pending prompts"
            )
            parts.append(promptPhrase)
        }
        let entities = counters.entityCounters
        parts.append(
            "Enemies \(entities.enemies), assets \(entities.assets), "
                + "treacheries \(entities.treacheries), events \(entities.events), "
                + "skills \(entities.skills), concealed \(entities.concealed), "
                + "cards \(entities.cards)"
        )
        return parts.joined(separator: ". ")
    }

    static func summary(act: BoardActNode) -> String {
        var parts = [
            "Act \(act.sequence.side.rawValue)\(act.sequence.step), \(act.cardCode.rawValue)",
        ]
        if act.flipped {
            parts.append("Flipped")
        }
        if let advanceCostSummary = act.advanceCostSummary {
            parts.append("Advance cost: \(advanceCostSummary)")
        }
        if !act.tokenCounts.isEmpty {
            parts.append(tokenCountsSummary(act.tokenCounts))
        }
        return parts.joined(separator: ". ")
    }

    static func summary(agenda: BoardAgendaNode) -> String {
        var parts = [
            "Agenda \(agenda.sequence.side.rawValue)\(agenda.sequence.step), "
                + "\(agenda.cardCode.rawValue)",
        ]
        if agenda.flipped {
            parts.append("Flipped")
        }
        parts.append("Doom \(agenda.doom)")
        if let doomThresholdSummary = agenda.doomThresholdSummary {
            parts.append("Doom threshold: \(doomThresholdSummary)")
        }
        if !agenda.tokenCounts.isEmpty {
            parts.append(tokenCountsSummary(agenda.tokenCounts))
        }
        return parts.joined(separator: ". ")
    }

    static func summary(location: BoardLocationNode) -> String {
        var parts = [
            "\(location.displayLabel), \(location.revealed ? "revealed" : "unrevealed") location",
        ]
        parts.append("Symbol \(location.symbol.rawValue)")
        if let shroudSummary = location.shroudSummary {
            parts.append("Shroud \(shroudSummary)")
        }
        parts.append("Clues \(location.clueCount)")
        if location.doomCount > 0 {
            parts.append("Doom \(location.doomCount)")
        }
        parts.append(
            "Investigators \(location.investigatorIDs.count), enemies \(location.enemyCount), "
                + "assets \(location.assetCount), events \(location.eventCount), "
                + "treacheries \(location.treacheryCount)"
        )
        if !location.otherTokenCounts.isEmpty {
            parts.append(tokenCountsSummary(location.otherTokenCounts))
        }
        if location.concealedCount > 0 {
            parts.append("Concealed cards \(location.concealedCount)")
        }
        if let placementSummary = location.placementSummary {
            parts.append(placementSummary)
        }
        return parts.joined(separator: ". ")
    }

    static func summary(enemyLocation location: BoardEnemyLocationNode) -> String {
        var parts = [
            "\(location.displayLabel), enemy-occupied location, "
                + "\(location.revealed ? "revealed" : "unrevealed")",
        ]
        if location.exhausted {
            parts.append("Exhausted")
        }
        if let shroudSummary = location.shroudSummary {
            parts.append("Shroud \(shroudSummary)")
        }
        parts.append(
            "Investigators \(location.investigatorIDs.count), enemies \(location.enemyCount), "
                + "assets \(location.assetCount), events \(location.eventCount), "
                + "treacheries \(location.treacheryCount)"
        )
        if !location.tokenCounts.isEmpty {
            parts.append(tokenCountsSummary(location.tokenCounts))
        }
        if location.concealedCount > 0 {
            parts.append("Concealed cards \(location.concealedCount)")
        }
        return parts.joined(separator: ". ")
    }

    static func summary(investigator: BoardInvestigatorNode) -> String {
        var parts = ["\(investigator.displayName), \(investigator.investigatorClass.rawValue)"]
        parts.append("Health \(investigator.health), sanity \(investigator.sanity)")
        let actionsPhrase = BoardDisplayFormatting.pluralized(
            investigator.remainingActions, singular: "action", plural: "actions"
        )
        parts.append("\(actionsPhrase) remaining")
        if investigator.isActiveInvestigator {
            parts.append("Active investigator")
        }
        if investigator.isLeadInvestigator {
            parts.append("Lead investigator")
        }
        if investigator.defeated {
            parts.append("Defeated")
        }
        if investigator.resigned {
            parts.append("Resigned")
        }
        if investigator.eliminated {
            parts.append("Eliminated")
        }
        if investigator.drivenInsane {
            parts.append("Driven insane")
        }
        if investigator.unhealedHorrorThisRound != 0 {
            parts.append("Unhealed horror this round \(investigator.unhealedHorrorThisRound)")
        }
        if let movementSummary = investigator.movementSummary {
            parts.append(movementSummary)
        }
        parts.append(investigator.placementSummary)
        return parts.joined(separator: ". ")
    }

    /// Announces exactly the same three-way categorization ``BoardChaosBagView`` renders
    /// on screen (see ``BoardChaosBagState/displayState``): no active scenario, a
    /// legitimately empty bag (never "unsupported"), or a populated bag's detailed counts.
    static func summary(chaosBag: BoardChaosBagState) -> String {
        switch chaosBag.displayState {
        case .noActiveScenario:
            "Chaos bag. No active scenario."
        case .empty:
            "Chaos bag. Empty."
        case let .populated(bagSummary):
            populatedChaosBagSummary(bagSummary)
        }
    }

    private static func populatedChaosBagSummary(_ chaosBag: BoardChaosBagSummary) -> String {
        var parts = ["Chaos bag"]
        if !chaosBag.poolCounts.isEmpty {
            parts.append("In bag: " + faceCountsSummary(chaosBag.poolCounts))
        }
        if !chaosBag.revealedCounts.isEmpty {
            parts.append("Revealed: " + faceCountsSummary(chaosBag.revealedCounts))
        }
        if !chaosBag.setAsideCounts.isEmpty {
            parts.append("Set aside: " + faceCountsSummary(chaosBag.setAsideCounts))
        }
        if let forceDrawFace = chaosBag.forceDrawFace {
            let humanized = BoardDisplayFormatting.humanizeTag(forceDrawFace.rawValue)
            parts.append("Forced draw: \(humanized)")
        }
        if chaosBag.hasPendingChoice {
            parts.append("Pending chaos bag resolution")
        }
        return parts.joined(separator: ". ")
    }

    private static func tokenCountsSummary(_ counts: [BoardTokenSummary]) -> String {
        counts.map { "\($0.token) \($0.count)" }.joined(separator: ", ")
    }

    private static func faceCountsSummary(_ counts: [BoardChaosFaceCount]) -> String {
        counts
            .map { "\(BoardDisplayFormatting.humanizeTag($0.face.rawValue)) \($0.count)" }
            .joined(separator: ", ")
    }
}
