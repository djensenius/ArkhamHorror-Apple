import SwiftUI

extension EnvironmentValues {
    @Entry var storyAssetCache: AssetCacheService?
}

struct StoryAssetImageView: View {
    let reference: StoryAssetReference
    @Environment(\.storyAssetCache) private var cacheService

    var body: some View {
        if let key = reference.assetKey, let cacheService {
            LoadedStoryAssetView(
                key: key, description: reference.accessibleDescription, cacheService: cacheService
            )
            .id(reference)
        } else {
            Label("Story image unavailable", systemImage: "exclamationmark.triangle")
                .accessibilityLabel("\(reference.accessibleDescription): unavailable")
        }
    }
}

private struct LoadedStoryAssetView: View {
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
                ProgressView("Loading \(description)")
            case let .success(image, accessibleDescription):
                Image(image, scale: 1, label: Text(verbatim: accessibleDescription))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 480, maxHeight: 320, alignment: .leading)
            case .failure:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Could not load \(description)", systemImage: "exclamationmark.triangle")
                    Button("Retry image", action: load)
                        .accessibilityLabel("Retry \(description)")
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear { loader.cancel() }
    }

    private func load() {
        loader.load(key, accessibleDescription: description)
    }
}
