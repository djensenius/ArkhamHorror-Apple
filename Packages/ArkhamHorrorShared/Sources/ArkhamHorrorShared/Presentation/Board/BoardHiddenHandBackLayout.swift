import CoreGraphics

struct BoardHiddenHandBackFanLayout: Sendable, Equatable {
    let spacing: CGFloat
    let totalWidth: CGFloat

    static func make(
        handCount: Int,
        availableWidth: CGFloat = BoardInvestigatorTileLayout.width,
        cardWidth: CGFloat = BoardInvestigatorTileLayout.hiddenHandBackSize.width,
        preferredSpacing: CGFloat = BoardInvestigatorTileLayout.hiddenHandBackSpacing
    ) -> BoardHiddenHandBackFanLayout {
        guard handCount > 0 else {
            return BoardHiddenHandBackFanLayout(spacing: preferredSpacing, totalWidth: 0)
        }
        guard handCount > 1 else {
            return BoardHiddenHandBackFanLayout(
                spacing: preferredSpacing,
                totalWidth: min(cardWidth, availableWidth)
            )
        }

        let gaps = CGFloat(handCount - 1)
        let preferredWidth = cardWidth * CGFloat(handCount) + preferredSpacing * gaps
        guard preferredWidth > availableWidth else {
            return BoardHiddenHandBackFanLayout(
                spacing: preferredSpacing,
                totalWidth: preferredWidth
            )
        }

        let overlappedSpacing = (availableWidth - cardWidth * CGFloat(handCount)) / gaps
        return BoardHiddenHandBackFanLayout(
            spacing: overlappedSpacing,
            totalWidth: availableWidth
        )
    }
}

enum BoardInvestigatorTileLayout {
    static let width: CGFloat = 272
    static let hiddenHandBackSize = CGSize(width: 32, height: 44)
    static let hiddenHandBackSpacing: CGFloat = 4
}
