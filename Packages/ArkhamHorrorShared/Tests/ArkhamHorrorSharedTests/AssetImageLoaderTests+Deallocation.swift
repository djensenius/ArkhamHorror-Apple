@testable import ArkhamHorrorShared
import Foundation
import Testing

/// The weak-self-across-suspension deallocation coverage for
/// ``AssetImageLoader``, split out of `AssetImageLoaderTests.swift` (which
/// retains the shared `withLoader`/`portraitKey`/`portraitURL`/
/// `waitForSettledState` helpers) purely to stay under SwiftLint's
/// `type_body_length`, the same way `AssetDiskCacheTouchTests` is split out
/// of `AssetDiskCacheTests`.
extension AssetImageLoaderTests {
    @Test(
        """
        Losing the loader's only strong owner deallocates it immediately — even while its own \
        fetch is still suspended/held on the network layer — because the in-flight task only \
        ever holds `self` weakly across a suspension point, never promoting it to a strong \
        reference for the task's whole lifetime
        """
    )
    func loaderDeallocatesPromptlyWhileItsOwnFetchIsHeldInFlight() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("ImageLoaderScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let limits = AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 10_000_000,
            diskBudgetBytes: 10_000_000
        )
        let memoryCache = AssetMemoryCache(limits: limits)
        let diskCache = try AssetDiskCache(directory: root, limits: limits)
        let transport = FakeAssetTransport()
        let service = AssetCacheService(
            memoryCache: memoryCache,
            diskCache: diskCache,
            transport: transport,
            digest: FakeDigestLookup(),
            limits: limits
        )

        var loader: AssetImageLoader? = AssetImageLoader(cacheService: service)
        weak let weakLoader: AssetImageLoader? = loader

        let key = try portraitKey()
        let url = portraitURL(for: key)
        await transport.hold(url)
        await transport.enqueue(.success(.success(AssetHTTPResponse(
            body: AssetImageFixtureBuilder.validJPEG(),
            contentType: "image/jpeg",
            etag: nil,
            lastModified: nil
        ))), for: url)

        loader?.load(key, accessibleDescription: "Investigator")
        await transport.waitForCallCount(1, for: url)

        // Drop the only strong owner while the loader's own fetch is
        // still suspended, held by the fake transport. A `self` that had
        // been promoted to a strong reference across that suspension
        // point would keep this instance alive until the held fetch
        // eventually resumed; this asserts deallocation happens right
        // away instead.
        loader = nil
        #expect(
            weakLoader == nil,
            """
            the loader must deallocate immediately once its owner drops it, even while its \
            own in-flight fetch is still held/suspended on the network layer
            """
        )

        // Release the held transport afterward so its internal polling
        // loop does not spin forever; by now nothing observes the result.
        await transport.release(url)
    }
}
