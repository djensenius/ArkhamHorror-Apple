import Foundation
import Observation

/// A `@MainActor`, per-request asset loader bridging ``AssetCacheService``
/// to a deterministic ``AssetLoadState`` a SwiftUI view can observe.
///
/// Concurrency safety mirrors `AppModel`: a monotonically increasing
/// `generation` counter is captured by every load task, and any state
/// mutation after its one suspension point (the cache service call) first
/// checks that the captured generation is still current, so a superseded or
/// externally cancelled load can never clobber a later one's state.
///
/// Deliberately holds no SwiftUI `Image` — only a validated `CGImage` — so
/// nothing non-`Sendable` ever needs to cross an actor boundary; a view
/// converts the published `CGImage` to `Image(decorative:scale:)` (or
/// `Image(_:scale:label:)`, pairing the caller-supplied accessible
/// description) only at display time. This type is intentionally not
/// referenced from any app navigation, `RootView`, or session composition
/// code; it is a standalone presentation building block.
@MainActor
@Observable
final class AssetImageLoader {
    private(set) var state: AssetLoadState = .idle

    @ObservationIgnored private let cacheService: AssetCacheService
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(cacheService: AssetCacheService) {
        self.cacheService = cacheService
    }

    /// Starts loading `key`, cancelling any load this instance previously
    /// started. `accessibleDescription` is carried through to the
    /// resulting ``AssetLoadState`` regardless of outcome.
    func load(_ key: AssetKey, accessibleDescription: String) {
        loadTask?.cancel()
        generation += 1
        let requestedGeneration = generation
        state = .loading(accessibleDescription: accessibleDescription)

        loadTask = Task { [weak self, cacheService] in
            guard let self else { return }
            do {
                let cached = try await cacheService.asset(for: key)
                guard generation == requestedGeneration else { return }
                let image = try AssetImageDecoder.decode(cached.payload)
                guard generation == requestedGeneration else { return }
                state = .success(image, accessibleDescription: accessibleDescription)
            } catch is CancellationError {
                // A superseded or externally cancelled load leaves state
                // alone: either a newer `load` already owns it, or
                // `cancel()` was called and idle/whatever state preceded
                // it is preserved deliberately.
            } catch {
                guard generation == requestedGeneration else { return }
                let assetError = (error as? AssetError) ??
                    .transportFailure(String(describing: error))
                state = .failure(assetError, accessibleDescription: accessibleDescription)
            }
        }
    }

    /// Cancels any in-flight load and resets to ``AssetLoadState/idle``.
    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        generation += 1
        state = .idle
    }
}
