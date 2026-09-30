import SwiftUI

struct BoardAssetImageView: View {
    let key: AssetKey
    let description: String
    @Environment(\.storyAssetCache) private var cacheService

    var body: some View {
        if let cacheService {
            LoadedBoardAssetImageView(
                key: key, description: description, cacheService: cacheService
            )
            .id(key)
        }
    }
}

private struct LoadedBoardAssetImageView: View {
    let key: AssetKey
    let description: String
    @State private var loader: AssetImageLoader

    init(key: AssetKey, description: String, cacheService: AssetCacheService) {
        self.key = key
        self.description = description
        _loader = State(initialValue: AssetImageLoader(cacheService: cacheService))
    }

    var body: some View {
        Group {
            switch loader.state {
            case .idle, .loading:
                ProgressView()
                    .accessibilityLabel("Loading \(description) art")
            case let .success(image, _):
                Image(image, scale: 1, label: Text(verbatim: "\(description) art"))
                    .resizable()
                    .scaledToFit()
            case .failure:
                EmptyView()
                    .accessibilityLabel("\(description) art unavailable")
            }
        }
        .onAppear {
            loader.loadIfIdle(key, accessibleDescription: "\(description) art")
        }
        .onDisappear { loader.cancelInFlight() }
    }
}
