enum BoardCardBadgeFormatter {
    static func cardBadges(_ card: BoardPlayerCardNode) -> [String] {
        var badges: [String] = []
        if let usesSummary = card.usesSummary {
            badges.append(usesSummary)
        }
        if let damage = card.damage, damage > 0 {
            badges.append("Damage \(damage)")
        }
        if let horror = card.horror, horror > 0 {
            badges.append("Horror \(horror)")
        }
        let representedTokens: Set = ["Damage", "Horror"]
        let tokenBadges = card.tokenCounts
            .filter { !representedTokens.contains($0.token) && $0.count >= 1 }
            .map { "\($0.token) \($0.count)" }
        badges.append(contentsOf: tokenBadges.filter { !badges.contains($0) })
        return badges
    }
}
