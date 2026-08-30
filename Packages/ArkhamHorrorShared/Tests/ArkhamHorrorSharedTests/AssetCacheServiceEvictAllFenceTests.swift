@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Regression coverage for ``AssetCacheService/evictAll()``'s typed
/// distinction between a durable-fence-commit failure (must propagate,
/// never be treated as if the clear had succeeded) and an ordinary
/// best-effort partial physical-deletion failure (survives as before,
/// see `AssetCacheServiceEvictAllTombstoneTests.swift`). Split into its
/// own file purely to stay under SwiftLint's `file_length`.
extension AssetCacheServiceTests {
    @Test(
        """
        evictAll() throws AssetError.clearFenceNotDurable — never silently succeeds — when the \
        durable cross-instance/cross-process clear-epoch bump itself cannot be committed, \
        distinguishing this from an ordinary best-effort partial physical-deletion failure
        """
    )
    func evictAllPropagatesAFenceCommitFailure() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let layers = makeService(diskCache: diskCache, limits: limits)

            let key = try cardArtKey("01001")
            let body = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            try await publishAsset(key, body: body, via: layers)

            // Fails the clear-epoch counter's own durable write -- the
            // fence commit itself, not any per-entry payload/metadata
            // removal -- so this models exactly "the durable authority
            // fence never advanced", never a partial physical-deletion
            // failure.
            await diskCache.directoryAccess.installFaultInjection(
                failSuffixes: [SecureCacheDirectory.clearEpochFileName]
            )

            await #expect(throws: AssetError.self) {
                try await layers.service.evictAll()
            }

            let failure = await layers.service.lastDiskPersistenceFailure
            guard case .clearFenceNotDurable = failure else {
                Issue.record("Expected .clearFenceNotDurable, got \(String(describing: failure))")
                return
            }
        }
    }

    @Test(
        """
        evictAll() does not throw for an ordinary post-fence, best-effort partial \
        physical-deletion failure -- only a fence-commit failure itself is fatal to this call
        """
    )
    func evictAllDoesNotThrowForAPartialPhysicalDeletionFailure() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let layers = makeService(diskCache: diskCache, limits: limits)

            let key = try cardArtKey("01001")
            let cacheKey = AssetCacheKey(
                for: key,
                candidates: AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            )
            try await publishAsset(
                key,
                body: AssetImageFixtureBuilder.validAVIF(width: 4, height: 4),
                via: layers
            )

            // Fails only this one entry's own removal -- the fence itself
            // (the clear-epoch bump) is left free to succeed normally.
            await diskCache.directoryAccess.installFaultInjection(
                failRemovePrefixes: ["\(cacheKey.digestHex)."]
            )

            // Must not throw: the fence itself still durably advanced.
            try await layers.service.evictAll()

            let failure = await layers.service.lastDiskPersistenceFailure
            #expect(failure != nil, "A partial physical-deletion failure must still be audited")
            if case .clearFenceNotDurable = failure {
                Issue.record(
                    "A partial deletion failure must not be classified as a fence failure"
                )
            }
        }
    }

    @Test(
        """
        evictAll() propagating AssetError.clearFenceNotDurable still leaves this instance's own \
        in-process global generation bumped and its memory cache cleared -- a failed fence commit \
        must never make this instance itself keep trusting or serving pre-clear content, even \
        though it could not prove a sibling instance/process would learn the same thing
        """
    )
    func evictAllFenceFailureStillClearsThisInstancesOwnState() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let layers = makeService(diskCache: diskCache, limits: limits)

            let key = try cardArtKey("01001")
            let body = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            try await publishAsset(key, body: body, via: layers)

            await diskCache.directoryAccess.installFaultInjection(
                failSuffixes: [SecureCacheDirectory.clearEpochFileName]
            )
            await #expect(throws: AssetError.self) {
                try await layers.service.evictAll()
            }

            // Clear the fault injection so a fresh fetch is actually
            // observable, then confirm the prior memory entry is gone (a
            // fresh network round trip is required) rather than this
            // instance still serving the pre-clear bytes it, itself,
            // already knows it just tried to clear.
            await diskCache.directoryAccess.installFaultInjection()
            let newBody = AssetImageFixtureBuilder.validAVIF(width: 8, height: 8)
            await layers.transport.enqueue(
                .success(successResult(body: newBody)),
                for: candidateURLs(for: key)[0]
            )
            let refetched = try await layers.service.asset(for: key)
            #expect(
                refetched.payload == newBody,
                "A failed fence commit must not resurrect pre-clear memory content"
            )
        }
    }
}
