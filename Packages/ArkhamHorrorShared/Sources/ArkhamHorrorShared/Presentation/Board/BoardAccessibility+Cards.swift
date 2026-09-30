import Foundation

extension BoardAccessibility {
    static func summary(
        playerCard card: BoardPlayerCardNode,
        displayName: String? = nil
    ) -> String {
        let name = displayName ?? card.displayName
        var parts = ["\(name), \(card.zone.displayTitle.lowercased()) card"]
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
        return parts.joined(separator: ". ")
    }

    static func summary(
        enemy: BoardEnemyNode,
        displayName: String? = nil,
        engagedInvestigatorName: String? = nil
    ) -> String {
        let name = displayName ?? enemy.displayName
        var parts = ["\(name), enemy"]
        if let cardCode = enemy.cardCode {
            parts.append("Code \(cardCode.rawValue)")
        }
        appendEnemyStats(enemy, to: &parts)
        if enemy.exhausted {
            parts.append("Exhausted")
        }
        if let engagedInvestigatorID = enemy.engagedInvestigatorID {
            parts.append(
                "Engaged with \(engagedInvestigatorName ?? engagedInvestigatorID.rawValue.rawValue)"
            )
        }
        let unrepresentedTokens = enemy.tokenCounts.filter { token in
            token.token != "Damage" && token.token != "Horror"
        }
        if !unrepresentedTokens.isEmpty {
            parts.append(tokenCountsSummary(unrepresentedTokens))
        }
        return parts.joined(separator: ". ")
    }

    static func summary(
        threatTreachery treachery: BoardThreatTreacheryNode,
        displayName: String? = nil
    ) -> String {
        let name = displayName ?? treachery.displayName
        var parts = ["\(name), threat area treachery"]
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
            parts.append("Damage taken \(damage)")
        }
        if let horror = enemy.horror {
            parts.append("Horror taken \(horror)")
        }
        if let attackDamage = enemy.attackDamage {
            parts.append("Attack damage \(attackDamage)")
        }
        if let attackHorror = enemy.attackHorror {
            parts.append("Attack horror \(attackHorror)")
        }
    }

    private static func tokenCountsSummary(_ counts: [BoardTokenSummary]) -> String {
        counts.map { "\($0.token) \($0.count)" }.joined(separator: ", ")
    }
}
