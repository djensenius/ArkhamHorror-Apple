import Foundation

extension BoardAccessibility {
    static func summary(playerCard card: BoardPlayerCardNode) -> String {
        var parts = ["\(card.displayName), \(card.zone.displayTitle.lowercased()) card"]
        if let cardCode = card.cardCode {
            parts.append("Code \(cardCode.rawValue)")
        }
        if let usesSummary = card.usesSummary {
            parts.append(usesSummary)
        }
        if let damage = card.damage, damage > 0 {
            parts.append("Damage \(damage)")
        }
        if let horror = card.horror, horror > 0 {
            parts.append("Horror \(horror)")
        }
        if !card.tokenCounts.isEmpty {
            parts.append(tokenCountsSummary(card.tokenCounts))
        }
        return parts.joined(separator: ". ")
    }

    static func summary(enemy: BoardEnemyNode) -> String {
        var parts = ["\(enemy.displayName), enemy"]
        if let cardCode = enemy.cardCode {
            parts.append("Code \(cardCode.rawValue)")
        }
        appendEnemyStats(enemy, to: &parts)
        if enemy.exhausted {
            parts.append("Exhausted")
        }
        if let engagedInvestigatorID = enemy.engagedInvestigatorID {
            parts.append("Engaged with \(engagedInvestigatorID.rawValue.rawValue)")
        }
        if !enemy.tokenCounts.isEmpty {
            parts.append(tokenCountsSummary(enemy.tokenCounts))
        }
        return parts.joined(separator: ". ")
    }

    static func summary(threatTreachery treachery: BoardThreatTreacheryNode) -> String {
        var parts = ["\(treachery.displayName), threat area treachery"]
        if let cardCode = treachery.cardCode {
            parts.append("Code \(cardCode.rawValue)")
        }
        if treachery.clueCount > 0 {
            parts.append("Clues \(treachery.clueCount)")
        }
        if !treachery.tokenCounts.isEmpty {
            parts.append(tokenCountsSummary(treachery.tokenCounts))
        }
        return parts.joined(separator: ". ")
    }

    private static func appendEnemyStats(_ enemy: BoardEnemyNode, to parts: inout [String]) {
        if let fight = enemy.fight {
            parts.append("Fight \(fight.displayValue)")
        }
        if let health = enemy.health {
            parts.append("Health \(health.displayValue)")
        }
        if let evade = enemy.evade {
            parts.append("Evade \(evade.displayValue)")
        }
        if let damage = enemy.damage {
            parts.append("Damage \(damage)")
        }
        if let horror = enemy.horror {
            parts.append("Horror \(horror)")
        }
    }

    private static func tokenCountsSummary(_ counts: [BoardTokenSummary]) -> String {
        counts.map { "\($0.token) \($0.count)" }.joined(separator: ", ")
    }
}
