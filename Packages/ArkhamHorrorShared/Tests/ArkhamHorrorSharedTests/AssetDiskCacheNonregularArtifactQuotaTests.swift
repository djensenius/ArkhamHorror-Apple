@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for a surviving **non-regular** entry (a directory, in these
/// tests -- the simplest non-regular type to plant deterministically
/// without root or special device permissions) occupying a name this
/// cache's accounting otherwise expects to be a plain file, at each of
/// the three places physical disk-quota accounting walks a directory
/// listing: an orphan-candidate `.tmp`/`.bin` name
/// (``AssetDiskCache/sweepOrphanFiles(names:referencedPayloadFilenames:)``),
/// an invalid `.meta.json` sidecar
/// (`AssetDiskCache+SidecarEntries.swift`'s `quarantineInvalidSidecar`),
/// and any other stray cache-owned name
/// (``AssetDiskCache/evictIfNeeded()``'s `accountedStrayCacheFileBytes`).
///
/// Before this fix, every one of these three code paths treated "not a
/// regular file" as "0 stranded bytes" -- silently excluding a surviving
/// directory (or FIFO/device node/symlink) from quota accounting
/// entirely, even though it still occupies a real directory slot (and,
/// for a directory, potentially arbitrary additional physical bytes this
/// cache has no way to safely enumerate without walking into it). Split
/// out of `AssetDiskCacheOrphanQuotaTests.swift`/
/// `AssetDiskCacheInvalidSidecarQuotaTests.swift` purely so each artifact
/// type's own regression stays self-contained.
extension AssetDiskCacheTests {
    @Test(
        """
        A directory surviving at an orphan-candidate .bin name (never referenced by any \
        valid metadata sidecar) durably disables further disk writes, rather than being \
        silently excluded from quota accounting as though it were zero bytes
        """
    )
    func nonregularOrphanCandidateDisablesWrites() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let rogueName = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" +
                ".rogueorphan.bin"
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(rogueName),
                withIntermediateDirectories: true
            )

            // Proactive locked accounting now runs before every write --
            // including this very first one -- so the rogue directory's
            // unaccountable size is discovered and disables writes before
            // this entry is ever published, rather than only affecting
            // some later write.
            let firstKey = try key("01001")
            let firstPayload = Data(count: 100)
            await #expect(throws: AssetError.self) {
                try await cache.set(
                    firstKey,
                    payload: firstPayload,
                    metadata: metadata(for: firstKey, payload: firstPayload)
                )
            }

            let secondKey = try key("01002")
            let secondPayload = Data(count: 100)
            await #expect(throws: AssetError.self) {
                try await cache.set(
                    secondKey,
                    payload: secondPayload,
                    metadata: metadata(for: secondKey, payload: secondPayload)
                )
            }
        }
    }

    @Test(
        """
        A directory surviving at a stray, otherwise-unreserved name (neither .meta.json, \
        .tmp, nor .bin) durably disables further disk writes, rather than being silently \
        excluded from quota accounting as though it were zero bytes
        """
    )
    func nonregularStrayArtifactDisablesWrites() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("rogue-reserved-marker"),
                withIntermediateDirectories: true
            )

            // Proactive locked accounting now runs before every write --
            // including this very first one -- so the rogue directory's
            // unaccountable size is discovered and disables writes before
            // this entry is ever published, rather than only affecting
            // some later write.
            let firstKey = try key("01001")
            let firstPayload = Data(count: 100)
            await #expect(throws: AssetError.self) {
                try await cache.set(
                    firstKey,
                    payload: firstPayload,
                    metadata: metadata(for: firstKey, payload: firstPayload)
                )
            }

            let secondKey = try key("01002")
            let secondPayload = Data(count: 100)
            await #expect(throws: AssetError.self) {
                try await cache.set(
                    secondKey,
                    payload: secondPayload,
                    metadata: metadata(for: secondKey, payload: secondPayload)
                )
            }
        }
    }

    @Test(
        """
        A directory surviving at an invalid .meta.json sidecar's name (which can never be \
        successfully decoded, nor removed by a plain unlink) durably disables further disk \
        writes, rather than the quarantine attempt's own failure being silently excluded \
        from quota accounting as though it were zero bytes
        """
    )
    func nonregularInvalidSidecarDisablesWrites() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let rogueHash = String(repeating: "a", count: 64)
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("\(rogueHash).meta.json"),
                withIntermediateDirectories: true
            )

            // Proactive locked accounting now runs before every write --
            // including this very first one -- so the rogue directory's
            // unaccountable size is discovered and disables writes before
            // this entry is ever published, rather than only affecting
            // some later write.
            let firstKey = try key("01001")
            let firstPayload = Data(count: 100)
            await #expect(throws: AssetError.self) {
                try await cache.set(
                    firstKey,
                    payload: firstPayload,
                    metadata: metadata(for: firstKey, payload: firstPayload)
                )
            }

            let secondKey = try key("01002")
            let secondPayload = Data(count: 100)
            await #expect(throws: AssetError.self) {
                try await cache.set(
                    secondKey,
                    payload: secondPayload,
                    metadata: metadata(for: secondKey, payload: secondPayload)
                )
            }
        }
    }
}
