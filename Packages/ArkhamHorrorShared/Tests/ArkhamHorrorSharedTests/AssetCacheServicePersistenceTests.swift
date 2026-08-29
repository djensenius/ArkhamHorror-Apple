@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Disk-persistence failure auditability for ``AssetCacheService/publish``.
/// Split out from `AssetCacheServiceTests.swift` (reusing its
/// `withScratchDirectory`/`cardArtKey`/`candidateURLs`/`successResult`
/// helpers, and `AssetDiskCacheTests.swift`'s `FailingFileManager`) purely
/// to stay under SwiftLint's `type_body_length`.
///
/// Each test below constructs ``AssetDiskCache`` and ``AssetCacheService``
/// directly inline (rather than through an intermediate helper function)
/// so the injected `FailingFileManager` — a `@unchecked Sendable`
/// -conforming subclass of the otherwise non-`Sendable` `FileManager` — is
/// passed to `AssetDiskCache.init` at its own concrete type in a direct,
/// same-region call. Routing it through any intervening function or
/// closure parameter defeats the compiler's region-based "sending to an
/// actor-isolated initializer" analysis, even though the direct call site
/// itself is provably safe (the value has no other live references).
extension AssetCacheServiceTests {
    @Test(
        """
        A disk-cache persistence failure during publish is captured for auditing, \
        but the resolved asset is still returned (in-memory cache remains usable)
        """
    )
    func diskPersistenceFailureIsAuditedNotFatal() async throws {
        try await withScratchDirectory { directory in
            let limits = AssetCacheLimits(
                maxEncodedBytes: 1_000_000,
                maxDimension: 8192,
                maxPixelCount: 32_000_000,
                memoryBudgetBytes: 10_000_000,
                diskBudgetBytes: 10_000_000
            )
            let failingFileManager = FailingFileManager()
            failingFileManager.failPathSuffixes = [".bin"]
            let memoryCache = AssetMemoryCache(limits: limits)
            let diskCache = try AssetDiskCache(
                directory: directory,
                limits: limits,
                fileManager: failingFileManager
            )
            let transport = FakeAssetTransport()
            let service = AssetCacheService(
                memoryCache: memoryCache,
                diskCache: diskCache,
                transport: transport,
                digest: FakeDigestLookup(),
                limits: limits
            )

            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(successResult()), for: urls[0])

            // The disk write fails (payload move injected to fail), but
            // resolution itself must still succeed since the asset is
            // already validated and stored in the in-memory cache.
            let asset = try await service.asset(for: key)
            #expect(asset.payload == AssetImageFixtureBuilder.syntheticAVIF(width: 4, height: 4))

            let failure = await service.lastDiskPersistenceFailure
            #expect(
                failure != nil,
                "A failed disk write must be captured for auditing, not silently swallowed"
            )
        }
    }

    @Test("A successful publish clears any previously recorded disk-persistence failure")
    func successfulPublishClearsPriorFailure() async throws {
        try await withScratchDirectory { directory in
            let limits = AssetCacheLimits(
                maxEncodedBytes: 1_000_000,
                maxDimension: 8192,
                maxPixelCount: 32_000_000,
                memoryBudgetBytes: 10_000_000,
                diskBudgetBytes: 10_000_000
            )
            let firstKey = try cardArtKey("01001")
            let firstCandidates = AssetLocator.candidates(
                for: firstKey,
                digest: FakeDigestLookup()
            )
            let firstCacheKey = AssetCacheKey(for: firstKey, candidates: firstCandidates)

            let failingFileManager = FailingFileManager()
            failingFileManager.failPathSuffixes = ["\(firstCacheKey.digestHex).bin"]
            let memoryCache = AssetMemoryCache(limits: limits)
            let diskCache = try AssetDiskCache(
                directory: directory,
                limits: limits,
                fileManager: failingFileManager
            )
            let transport = FakeAssetTransport()
            let service = AssetCacheService(
                memoryCache: memoryCache,
                diskCache: diskCache,
                transport: transport,
                digest: FakeDigestLookup(),
                limits: limits
            )

            let firstURLs = candidateURLs(for: firstKey)
            await transport.enqueue(.success(successResult()), for: firstURLs[0])
            _ = try await service.asset(for: firstKey)
            let firstFailure = await service.lastDiskPersistenceFailure
            #expect(firstFailure != nil)

            // A different key's payload filename does not match the
            // injected failure suffix, so this publish succeeds and must
            // clear the previously recorded failure.
            let secondKey = try cardArtKey("01002")
            let secondURLs = candidateURLs(for: secondKey)
            await transport.enqueue(.success(successResult()), for: secondURLs[0])
            _ = try await service.asset(for: secondKey)
            let secondFailure = await service.lastDiskPersistenceFailure
            #expect(secondFailure == nil)
        }
    }
}
