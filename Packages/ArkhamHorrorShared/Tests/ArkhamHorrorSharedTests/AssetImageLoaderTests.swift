@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("AssetImageLoader")
@MainActor
struct AssetImageLoaderTests {
    func withLoader(
        transport: FakeAssetTransport = FakeAssetTransport(),
        _ body: (AssetImageLoader, FakeAssetTransport) async throws -> Void
    ) async throws {
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
        let service = AssetCacheService(
            memoryCache: memoryCache,
            diskCache: diskCache,
            transport: transport,
            digest: FakeDigestLookup(),
            limits: limits
        )
        let loader = AssetImageLoader(cacheService: service)
        try await body(loader, transport)
    }

    func portraitKey(_ rawCardCode: String = "01001") throws -> AssetKey {
        let identifier = try AssetIdentifier.cardCode(rawCardCode)
        return AssetKey(category: .portrait(identifier))
    }

    func portraitURL(for key: AssetKey) -> URL {
        AssetLocator.candidates(for: key, digest: FakeDigestLookup())[0].url(base: key.source)
    }

    /// Polls (test-only) until `loader.state` stops being `.loading`, since
    /// the loader mutates state asynchronously on `@MainActor` after its
    /// cache-service suspension.
    ///
    /// The default is deliberately generous for the same reason
    /// `FakeAssetTransport.waitForCallCount`'s is: under a heavily parallel
    /// CI run sharing this package's full (contract + asset) test suite in
    /// one process, ordinary scheduling contention can legitimately delay
    /// when this polled `@MainActor` state mutation is observed, even
    /// though nothing is actually hung.
    func waitForSettledState(
        _ loader: AssetImageLoader,
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while case .loading = loader.state, DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @Test("Starts in the idle state with no accessible description")
    func startsIdle() async throws {
        try await withLoader { loader, _ in
            #expect(loader.state == .idle)
        }
    }

    @Test(
        "A successful load transitions from loading to success, carrying the accessible description"
    )
    func successfulLoadTransitionsThroughLoadingToSuccess() async throws {
        try await withLoader { loader, transport in
            let key = try portraitKey()
            let url = portraitURL(for: key)
            await transport.enqueue(.success(.success(AssetHTTPResponse(
                body: AssetImageFixtureBuilder.validJPEG(),
                contentType: "image/jpeg",
                etag: nil,
                lastModified: nil
            ))), for: url)

            loader.load(key, accessibleDescription: "Roland Banks")
            #expect(loader.state.accessibleDescription == "Roland Banks")

            await waitForSettledState(loader)
            guard case let .success(_, description) = loader.state else {
                Issue.record("Expected .success, got \(loader.state)")
                return
            }
            #expect(description == "Roland Banks")
        }
    }

    @Test(
        "A failed load (every candidate not found) transitions to failure with the typed error"
    )
    func failedLoadTransitionsToFailure() async throws {
        try await withLoader { loader, transport in
            let key = try portraitKey()
            let url = portraitURL(for: key)
            await transport.enqueue(.success(.notFound), for: url)

            loader.load(key, accessibleDescription: "Missing Investigator")
            await waitForSettledState(loader)

            guard case let .failure(error, description) = loader.state else {
                Issue.record("Expected .failure, got \(loader.state)")
                return
            }
            #expect(error == .candidatesExhausted)
            #expect(description == "Missing Investigator")
            #expect(
                loader.loadTask == nil,
                "A definitively failed load must not retain its finished task"
            )
        }
    }

    @Test(
        "Calling load again before the first completes supersedes it: only the newest result wins"
    )
    func newerLoadSupersedesOlder() async throws {
        try await withLoader { loader, transport in
            let firstKey = try portraitKey("01001")
            let secondKey = try portraitKey("01002")
            let firstURL = portraitURL(for: firstKey)
            let secondURL = portraitURL(for: secondKey)

            // Hold the first fetch so it cannot complete before the second
            // load starts and (quickly) succeeds.
            await transport.hold(firstURL)
            await transport.enqueue(.success(.success(AssetHTTPResponse(
                body: AssetImageFixtureBuilder.validJPEG(),
                contentType: "image/jpeg",
                etag: nil,
                lastModified: nil
            ))), for: firstURL)
            await transport.enqueue(.success(.success(AssetHTTPResponse(
                body: AssetImageFixtureBuilder.validJPEG(width: 8, height: 8),
                contentType: "image/jpeg",
                etag: nil,
                lastModified: nil
            ))), for: secondURL)

            loader.load(firstKey, accessibleDescription: "First")
            await transport.waitForCallCount(1, for: firstURL)
            loader.load(secondKey, accessibleDescription: "Second")
            await waitForSettledState(loader)

            // Release the first fetch well after the second has settled;
            // its stale completion must never overwrite the newer state.
            await transport.release(firstURL)
            try await Task.sleep(nanoseconds: 50_000_000)

            guard case let .success(_, description) = loader.state else {
                Issue.record("Expected .success, got \(loader.state)")
                return
            }
            #expect(
                description == "Second",
                "A stale, superseded load must never clobber a newer load's state"
            )
            #expect(
                loader.loadTask == nil,
                """
                the newer (second) load's own completion must have cleared `loadTask`, and the \
                stale first load's later, generation-mismatched completion must not have \
                resurrected it
                """
            )
        }
    }

    @Test("cancel() resets to idle and prevents any in-flight load from later publishing")
    func cancelResetsToIdleAndSuppressesStaleCompletion() async throws {
        try await withLoader { loader, transport in
            let key = try portraitKey()
            let url = portraitURL(for: key)
            await transport.hold(url)
            await transport.enqueue(.success(.success(AssetHTTPResponse(
                body: AssetImageFixtureBuilder.validJPEG(),
                contentType: "image/jpeg",
                etag: nil,
                lastModified: nil
            ))), for: url)

            loader.load(key, accessibleDescription: "Investigator")
            await transport.waitForCallCount(1, for: url)
            loader.cancel()
            #expect(loader.state == .idle)
            #expect(loader.loadTask == nil)

            await transport.release(url)
            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(
                loader.state == .idle,
                "A cancelled load's late completion must never overwrite the idle state"
            )
            #expect(
                loader.loadTask == nil,
                """
                a cancelled load's own generation-mismatched completion must not resurrect \
                loadTask
                """
            )
        }
    }

    @Test(
        """
        Cancelling exactly between decode finishing and the success-state publish (the one \
        window `generation` alone cannot observe, since cancel() itself is what bumps \
        generation) must still leave state alone rather than publishing a stale success
        """
    )
    func cancellingBetweenDecodeCompletionAndPublishLeavesStateAlone() async throws {
        try await withLoader { loader, transport in
            let key = try portraitKey()
            let url = portraitURL(for: key)
            await transport.enqueue(.success(.success(AssetHTTPResponse(
                body: AssetImageFixtureBuilder.validJPEG(),
                contentType: "image/jpeg",
                etag: nil,
                lastModified: nil
            ))), for: url)

            // Fires synchronously once the decode has completed but
            // before this still-current-generation load publishes
            // `.success` — the exact window under test. Calling
            // `cancel()` from here deterministically reproduces
            // "externally cancelled in this narrow window" without any
            // timing dependency.
            loader.onDecodeCompletedBeforePublish = { loader.cancel() }

            loader.load(key, accessibleDescription: "Investigator")
            await waitForSettledState(loader)

            #expect(
                loader.state == .idle,
                """
                Cancelling in this window must leave state at the idle cancel() set it to, \
                never a stale published .success
                """
            )
            #expect(loader.loadTask == nil)
        }
    }
}
