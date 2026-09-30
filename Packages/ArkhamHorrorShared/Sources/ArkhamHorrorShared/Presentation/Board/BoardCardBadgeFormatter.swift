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
        var representedTokens: Set = ["Damage", "Horror"]
        if card.usesSummary != nil {
            representedTokens.formUnion(card.tokenCounts.compactMap { token in
                isUseToken(token.token) ? token.token : nil
            })
        }
        let tokenBadges = card.tokenCounts
            .filter { !representedTokens.contains($0.token) && $0.count >= 1 }
            .map { "\($0.token) \($0.count)" }
        badges.append(contentsOf: tokenBadges)
        return badges
    }

    private static func isUseToken(_ token: String) -> Bool {
        token != "Damage" && token != "Horror" && token != "Clue" && token != "Doom"
    }
}
