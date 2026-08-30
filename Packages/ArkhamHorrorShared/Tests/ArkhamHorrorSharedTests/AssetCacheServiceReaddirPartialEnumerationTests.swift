@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Regression coverage for ``SecureCacheDirectory/listNames()``'s
/// errno-checked `readdir` loop: a directory listing that fails partway
/// through enumeration (a genuine I/O error, as opposed to reaching
/// genuine end-of-directory) must never be silently indistinguishable
/// from a short, fully-listed directory. Before the fix, `readdir`
/// returning `NULL` was treated unconditionally as end-of-directory,
/// letting `removeAll()`/`evictAll()` believe every on-disk survivor had
/// been enumerated while entries this call never actually saw remained
/// physically present. Under the mandatory-online-revalidation model
/// (see ``AssetDiskCache``'s own doc comment), no on-disk survivor is
/// ever independently trusted regardless of enumeration outcome, but the
/// failure itself must still be audited rather than silently treated as
/// a clean, complete success. Split out of
/// `AssetCacheServiceEvictAllTombstoneTests.swift` purely to stay under
/// this package's `file_length` convention.
extension AssetCacheServiceTests {
    @Test(
        """
        evictAll() still leaves every surviving entry subject to mandatory online \
        revalidation -- never independently trusted from disk again -- when the underlying \
        directory listing fails partway through enumeration (readdir returning NULL with a \
        nonzero errno), exactly as it already does when listing fails outright before ever \
        reading a single entry
        """
    )
    func evictAllFailsClosedOnPartialReaddirEnumeration() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let layers = makeService(diskCache: diskCache, limits: limits)

            let firstKey = try cardArtKey("01001")
            let secondKey = try cardArtKey("01002")

            let firstBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            let secondBody = AssetImageFixtureBuilder.validAVIF(width: 6, height: 6)
            try await publishAsset(firstKey, body: firstBody, via: layers)
            try await publishAsset(secondKey, body: secondBody, via: layers)

            // Two published entries (each a metadata sidecar + payload
            // file) plus the lock file mean the directory holds at least
            // 5 real entries; forcing a simulated failure after just 1 is
            // read guarantees this is a genuine *partial* enumeration,
            // never one that happens to land exactly on the true count.
            await diskCache.directoryAccess.installFaultInjection(
                failReaddirAfterEntryCount: 1
            )

            await layers.service.evictAll()

            let failure = await layers.service.lastDiskPersistenceFailure
            #expect(
                failure != nil,
                "A partial-enumeration listing failure must be audited, not swallowed as success"
            )

            // The critical assertion, in the mandatory-online-
            // revalidation model: regardless of whether either surviving
            // key ended up in the in-process, best-effort `tombstonedKeys`
            // set (which a severe enough enumeration failure may not be
            // able to populate at all), neither key may ever be served
            // again without a fresh, live network round trip — a fresh
            // `AssetCacheService`/`AssetDiskCache` triple over the same
            // directory (no shared in-memory state) proves this: both
            // keys' still-fully-intact entries are refetched from the
            // network rather than trusted from disk.
            let restartedLayers = try makeService(directory: directory, limits: limits)
            let firstFreshBody = AssetImageFixtureBuilder.validAVIF(width: 5, height: 5)
            let secondFreshBody = AssetImageFixtureBuilder.validAVIF(width: 7, height: 7)
            await restartedLayers.transport.enqueue(
                .success(successResult(body: firstFreshBody)),
                for: candidateURLs(for: firstKey)[0]
            )
            await restartedLayers.transport.enqueue(
                .success(successResult(body: secondFreshBody)),
                for: candidateURLs(for: secondKey)[0]
            )
            let firstAfterRestart = try await restartedLayers.service.asset(for: firstKey)
            #expect(
                firstAfterRestart.payload == firstFreshBody,
                "Every key must be refetched, never trusted from disk after such a failure"
            )
            let secondAfterRestart = try await restartedLayers.service.asset(for: secondKey)
            #expect(
                secondAfterRestart.payload == secondFreshBody,
                "Every key must be refetched, never trusted from disk after such a failure"
            )
        }
    }
}
