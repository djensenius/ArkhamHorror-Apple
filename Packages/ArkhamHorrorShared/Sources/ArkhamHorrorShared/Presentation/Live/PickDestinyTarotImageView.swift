import SwiftUI

/// A small tarot card thumbnail for a Pick Destiny row, mirroring the web
/// client's `PickDestiny.vue`: the `tarot/tarot-N.jpg` art, rotated 180°
/// when the card is reversed. Art is fetched at runtime through the shared
/// story asset cache (never bundled). The image is decorative: the row's
/// accessibility label names the arcana and its value names the facing.
struct PickDestinyTarotImageView: View {
    static let cornerRadius: CGFloat = 6

    let tarot: QuestionPresentation.TarotCard
    let isCompact: Bool
    @Environment(\.storyAssetCache) private var cacheService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The thumbnail size, at the web client's 4:7 tarot aspect ratio.
    /// Compact layouts use a smaller card so several rows fit in the
    /// compact (240pt) card list.
    static func size(isCompact: Bool) -> CGSize {
        isCompact ? CGSize(width: 36, height: 63) : CGSize(width: 60, height: 105)
    }

    /// The hosted, English-only tarot art key, or `nil` for an arcana the
    /// web client has no image for (no image is shown).
    static func assetKey(forArcana arcana: String) -> AssetKey? {
        TarotArcanaArt(rawValue: arcana).map { AssetKey(category: .tarot($0)) }
    }

    /// Degrees the art is rotated for a facing (web: `rotateZ(180deg)`).
    static func rotationDegrees(for facing: QuestionPresentation.TarotCard.Facing) -> Double {
        facing == .reversed ? 180 : 0
    }

    var body: some View {
        let size = Self.size(isCompact: isCompact)
        Group {
            if let cacheService, let key = Self.assetKey(forArcana: tarot.arcana) {
                LoadedPickDestinyTarotImageView(key: key, cacheService: cacheService)
                    .id(key)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                    .rotationEffect(.degrees(Self.rotationDegrees(for: tarot.facing)))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.25),
                        value: tarot.facing
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct LoadedPickDestinyTarotImageView: View {
    let key: AssetKey
    @State private var loader: AssetImageLoader

    init(key: AssetKey, cacheService: AssetCacheService) {
        self.key = key
        _loader = State(initialValue: AssetImageLoader(cacheService: cacheService))
    }

    var body: some View {
        Group {
            switch loader.state {
            case .idle, .loading:
                ProgressView()
            case let .success(image, _):
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            case .failure:
                // No retry (matches BoardAssetImageView); a faint card-shaped
                // fill keeps the row from showing an empty hole.
                RoundedRectangle(cornerRadius: PickDestinyTarotImageView.cornerRadius)
                    .fill(Color.secondary.opacity(0.15))
            }
        }
        .onAppear {
            loader.loadIfIdle(key, accessibleDescription: "Tarot card art")
        }
        .onDisappear { loader.cancelInFlight() }
    }
}
