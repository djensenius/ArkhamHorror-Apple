@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Task-retention behavior for ``AssetImageLoader``'s private `loadTask`,
/// split out from `AssetImageLoaderTests.swift` purely to stay under
/// SwiftLint's `type_body_length`, the same way `AssetCacheServiceTests` is
/// split by concern across sibling files.
///
/// Prior to this fix, a completed task (success, failure, or a still-current
/// generation's own cancellation) was left referenced by `loadTask` until the
/// next `load()`/`cancel()` call, unnecessarily extending the lifetime of
/// whatever the finished task's closure had captured. `loadTask` exposes a
/// `private(set)` getter solely so these tests can observe that a terminal
/// completion promptly clears it.
extension AssetImageLoaderTests {
    @Test(
        """
        A terminal completion (success, failure, or a still-current generation's own \
        cancellation) clears `loadTask` rather than retaining the finished task — and \
        whatever it closed over — until the next `load()`/`cancel()`
        """
    )
    func terminalCompletionClearsLoadTask() async throws {
        try await withLoader { loader, transport in
            let key = try portraitKey()
            let url = portraitURL(for: key)
            await transport.enqueue(.success(.success(AssetHTTPResponse(
                body: AssetImageFixtureBuilder.validJPEG(),
                contentType: "image/jpeg",
                etag: nil,
                lastModified: nil
            ))), for: url)

            #expect(loader.loadTask == nil)
            loader.load(key, accessibleDescription: "Roland Banks")
            #expect(loader.loadTask != nil)

            await waitForSettledState(loader)
            // Poll briefly: the task itself clears `loadTask` from within
            // its own body immediately after publishing `.success`, which
            // is observably a moment after `waitForSettledState` sees the
            // new `state`. Generous, for the same CI-contention reasons as
            // `waitForSettledState`'s own default.
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            while loader.loadTask != nil, DispatchTime.now().uptimeNanoseconds < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            #expect(
                loader.loadTask == nil,
                "A successfully completed load must not retain its finished task"
            )
        }
    }
}
