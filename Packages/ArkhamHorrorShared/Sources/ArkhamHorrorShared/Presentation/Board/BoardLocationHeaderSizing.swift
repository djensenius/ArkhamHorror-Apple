import SwiftUI

enum BoardLocationHeaderSizing {
    /// Matches ``BoardEntityTile``'s 44pt minimum touch/focus target. Enemy layout may
    /// compress a location header down to this height, but never below it.
    static let minimumInteractiveHeight: CGFloat = 44

    static func drawnHeight(naturalHeight: CGFloat, maximumHeight: CGFloat?) -> CGFloat {
        guard let maximumHeight else { return naturalHeight }
        return min(naturalHeight, maximumHeight)
    }
}

struct BoardLocationHeaderClampLayout: Layout {
    let maximumHeight: CGFloat?

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let naturalSize = subview.sizeThatFits(.init(width: proposal.width, height: nil))
        return CGSize(
            width: proposal.width ?? naturalSize.width,
            height: BoardLocationHeaderSizing.drawnHeight(
                naturalHeight: naturalSize.height,
                maximumHeight: maximumHeight
            )
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: .init(width: bounds.width, height: nil)
        )
    }
}
