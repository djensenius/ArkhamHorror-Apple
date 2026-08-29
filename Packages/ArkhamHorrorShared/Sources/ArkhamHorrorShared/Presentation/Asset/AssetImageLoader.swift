import CoreGraphics
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
    /// Not `private`: exposed at `internal` visibility solely so tests can
    /// assert it is cleared on terminal completion (see
    /// `AssetImageLoaderTests`), never read or written by anything outside
    /// this type in production code.
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?

    init(cacheService: AssetCacheService) {
        self.cacheService = cacheService
    }

    deinit {
        // The in-flight task holds `[weak self]` (see `load` below) and
        // already re-checks that weak reference after every suspension
        // rather than promoting it to a strong reference for the task's
        // whole lifetime, so this instance's own deallocation is never
        // blocked on that task. This proactively cancels it anyway,
        // rather than leaving it to run to a completion nothing will ever
        // observe: `cacheService.asset(for:)`/the decode task group both
        // cooperate with cancellation, so this promptly releases the
        // network/decode work instead of letting it linger after its
        // last owner is gone.
        loadTask?.cancel()
    }

    /// Starts loading `key`, cancelling any load this instance previously
    /// started. `accessibleDescription` is carried through to the
    /// resulting ``AssetLoadState`` regardless of outcome.
    func load(_ key: AssetKey, accessibleDescription: String) {
        loadTask?.cancel()
        generation += 1
        let requestedGeneration = generation
        state = .loading(accessibleDescription: accessibleDescription)

        // Deliberately never unwraps `weak self` into a long-lived local
        // `self` that would then be held strongly for the rest of this
        // closure: doing so across an `await` would silently promote a
        // weak reference into a strong one spanning every suspension
        // point below (the network fetch and the decode task group),
        // keeping this instance alive for the task's whole duration even
        // if every other owner has already released it. Instead, `self`
        // is re-checked via a fresh `guard let self` immediately after
        // each suspension, so a caller-side deallocation in the interim
        // is observed as `self == nil` right away rather than being
        // masked by an already-promoted strong reference.
        loadTask = Task { [weak self, cacheService] in
            do {
                let cached = try await cacheService.asset(for: key)
                // Uses optional chaining rather than `guard let self` here
                // (unlike the checkpoints below, which have no further
                // `await` after them and so are safe to bind strongly):
                // binding `self` into a shadowed local at this point would
                // hold it strongly across the *next* suspension point (the
                // decode task group below), reintroducing exactly the
                // retain-across-suspension this design avoids. A `nil`
                // `self` here is indistinguishable from (and handled the
                // same as) a stale generation.
                guard self?.generation == requestedGeneration else { return }
                // Decoding (signature/dimension validation plus the full
                // platform bitmap decode) is CPU-bound and can be
                // expensive for large assets; running it as a child task
                // in a throwing task group keeps this MainActor-isolated
                // loader responsive instead of blocking the main thread
                // for the duration of the decode, while — unlike
                // `Task.detached`, which does not inherit cancellation —
                // still participating in cooperative cancellation: if
                // this outer task is cancelled or superseded, cancellation
                // propagates to the child task. `AssetImageDecoder.decode`
                // itself is synchronous and checks for cancellation
                // nowhere, so a cancellation that arrives mid-decode does
                // not interrupt the decode itself; it is only observed
                // below, once the decode has actually finished, when
                // `group.next()` throws `CancellationError` instead of
                // returning the decoded image. Only the final state
                // publish below hops back onto the MainActor.
                let payload = cached.payload
                let image = try await withThrowingTaskGroup(of: CGImage.self) { group in
                    group.addTask {
                        try AssetImageDecoder.decode(payload)
                    }
                    guard let decoded = try await group.next() else {
                        throw CancellationError()
                    }
                    return decoded
                }
                guard let self, generation == requestedGeneration else { return }
                state = .success(image, accessibleDescription: accessibleDescription)
                loadTask = nil
            } catch is CancellationError {
                // A superseded or externally cancelled load leaves state
                // alone: either a newer `load` already owns it, or
                // `cancel()` was called and idle/whatever state preceded
                // it is preserved deliberately. Only clears `loadTask`
                // when this generation is still current: if a newer
                // `load`/`cancel()` already ran, `loadTask` already
                // refers to that call's own task (or is already `nil`),
                // and this stale branch must not overwrite it.
                if let self, generation == requestedGeneration {
                    loadTask = nil
                }
            } catch {
                guard let self, generation == requestedGeneration else { return }
                let assetError = (error as? AssetError) ??
                    .transportFailure(String(describing: error))
                state = .failure(assetError, accessibleDescription: accessibleDescription)
                loadTask = nil
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
