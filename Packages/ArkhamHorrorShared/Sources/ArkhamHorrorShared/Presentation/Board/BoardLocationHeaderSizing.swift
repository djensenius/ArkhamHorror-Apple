import SwiftUI

enum BoardLocationHeaderSizing {
    /// Matches ``BoardEntityTile``'s 44pt minimum touch/focus target. Enemy layout may
    /// compress a location header down to this height, but never below it.
    static let minimumInteractiveHeight: CGFloat = 44

    static func drawnHeight(naturalHeight: CGFloat, maximumHeight: CGFloat?) -> CGFloat {
        guard let maximumHeight else { return naturalHeight }
        return min(naturalHeight, maximumHeight)
    }

    static func reportedWidth(naturalWidth: CGFloat, proposedWidth: CGFloat?) -> CGFloat {
        guard let proposedWidth else { return naturalWidth }
        return min(naturalWidth, proposedWidth)
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
        let measuredSize = measuredSubviewSize(subview, proposal: proposal)
        return CGSize(
            width: BoardLocationHeaderSizing.reportedWidth(
                naturalWidth: measuredSize.width,
                proposedWidth: proposal.width
            ),
            height: BoardLocationHeaderSizing.drawnHeight(
                naturalHeight: measuredSize.height,
                maximumHeight: maximumHeight
            )
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let measuredSize = measuredSubviewSize(subview, proposal: proposal)
        let proposedHeight = BoardLocationHeaderSizing.drawnHeight(
            naturalHeight: measuredSize.height,
            maximumHeight: maximumHeight
        )
        subview.place(
            at: CGPoint(x: bounds.midX, y: bounds.minY),
            anchor: .top,
            proposal: .init(width: proposal.width, height: proposedHeight)
        )
    }

    private func measuredSubviewSize(
        _ subview: LayoutSubview,
        proposal: ProposedViewSize
    ) -> CGSize {
        let naturalSize = subview.sizeThatFits(.init(width: proposal.width, height: nil))
        guard let maximumHeight, naturalSize.height > maximumHeight else {
            return naturalSize
        }
        return subview.sizeThatFits(.init(width: proposal.width, height: maximumHeight))
    }
}
