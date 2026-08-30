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
/// been enumerated (and so was safe to un-tombstone) while entries this
/// call never actually saw remained physically present and unprotected.
/// Split out of `AssetCacheServiceEvictAllTombstoneTests.swift` purely to
/// stay under this package's `file_length` convention.
extension AssetCacheServiceTests {
    @Test(
        """
        evictAll() escalates to the whole-cache disabled marker -- rather than reporting \
        success, or tombstoning only a partial survivor snapshot -- when the underlying \
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
            let firstCandidates = AssetLocator.candidates(for: firstKey, digest: FakeDigestLookup())
            let firstCacheKey = AssetCacheKey(for: firstKey, candidates: firstCandidates)

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

            // The critical assertion: with the pre-fix bug, `listNames()`
            // would have silently reported only the 1 entry actually read
            // as if that were the *complete* directory contents, letting
            // `removeAll()` "succeed" having removed just that one file,
            // report no failure, and clear tombstones -- while the other
            // key's still-fully-intact entry remains servable. The fix
            // must instead disable disk reads for *every* key, including
            // ones `entryKeyHashes()`'s own retry can no longer identify
            // individually because that same fault also makes it fail.
            let firstStillAccessible = try await diskCache.get(firstCacheKey)
            #expect(
                firstStillAccessible == nil,
                """
                Every key must be refused after a listing failure this severe: the surviving \
                entry set could not be determined at all, so no specific key can be safely \
                un-tombstoned
                """
            )
        }
    }
}
