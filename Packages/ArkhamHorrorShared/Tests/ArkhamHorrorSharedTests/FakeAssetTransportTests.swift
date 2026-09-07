@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Direct coverage of ``FakeAssetTransport``'s own held-URL polling loop,
/// independent of any ``AssetCacheService`` consumer: proves the fake
/// genuinely honors its documented contract ("responding to cancellation
/// like a real network call would") rather than only appearing to, in
/// consumer tests, because of an incidental release.
@Suite("FakeAssetTransport")
struct FakeAssetTransportTests {
    @Test(
        """
        Cancelling a task suspended in fetch(_:limits:) while its URL is \
        held throws CancellationError promptly, without the test ever \
        calling release(_:) -- proving the held-URL loop itself observes \
        cancellation rather than only unblocking once released
        """
    )
    func cancellingWhileHeldThrowsWithoutRelease() async throws {
        let transport = FakeAssetTransport()
        let url = try #require(URL(string: "https://example.com/a.png"))
        await transport.hold(url)

        let task = Task {
            try await transport.fetch(
                AssetHTTPRequest(url: url),
                limits: AssetCacheLimits(
                    maxEncodedBytes: 1_000_000,
                    maxDimension: 8192,
                    maxPixelCount: 32_000_000,
                    memoryBudgetBytes: 10_000_000,
                    diskBudgetBytes: 10_000_000
                )
            )
        }
        await transport.waitForCallCount(1, for: url)
        // Give the fetch time to actually enter the held-URL polling loop
        // before cancelling, rather than racing its very first iteration.
        try await Task.sleep(nanoseconds: 10_000_000)

        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }
}
