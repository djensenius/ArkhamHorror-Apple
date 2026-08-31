@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage proving ``AssetDiskCache/set(_:payload:metadata:)`` independently
/// recomputes and verifies `payloadSHA256Hex` against the actual `payload`
/// bytes (not merely its shape), split out of `AssetDiskCacheTests.swift`
/// (which retains the shared `withScratchDirectory`/`key`/`metadata`/
/// `smallLimits` helpers) purely to stay under SwiftLint's `type_body_length`.
extension AssetDiskCacheTests {
    @Test(
        """
        set(_:payload:metadata:) rejects a payloadSHA256Hex that does not actually match the \
        payload bytes being written, throwing before anything reaches disk — a content-addressed \
        filename is only trustworthy as long as it always matches what is written under it, so a \
        caller-supplied hash must never merely look like a valid hash: it must actually be one
        """
    )
    func setRejectsAMismatchedPayloadHash() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            let wrongHashMetadata = metadata(for: cacheKey, payload: Data([9, 9, 9]))

            await #expect(throws: AssetError.self) {
                try await cache.set(cacheKey, payload: payload, metadata: wrongHashMetadata)
            }

            // Excludes the cache's own reserved cross-process lock file
            // (`SecureCacheDirectory.lockFileName`), durable clear-
            // epoch counter (`SecureCacheDirectory.clearEpochFileName`),
            // and durable root-authority-initialization marker
            // (`SecureCacheDirectory.rootInitMarkerFileName`) -- all of
            // which are expected to persist for the cache's entire
            // lifetime regardless of what entries it holds (the root
            // marker in particular is durably created on this first-ever
            // operation against a pristine root, before this call's own
            // hash check even runs), and none of which is itself a cache
            // entry.
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter {
                    $0 != SecureCacheDirectory.lockFileName
                        && $0 != SecureCacheDirectory.clearEpochFileName
                        && $0 != SecureCacheDirectory.rootInitMarkerFileName
                        && $0 != SecureCacheDirectory.rootFreshnessWitnessFileName
                        && $0 != AssetDiskCache.keyUsageFloorIndexFileName
                        && $0 != SecureCacheDirectory.ticketSequenceFileName
                }
            #expect(contents.isEmpty, "A rejected mismatched hash must write nothing at all")
            let fetched = try await cache.get(cacheKey)
            #expect(fetched == nil)
        }
    }

    @Test(
        """
        set(_:payload:metadata:) rejecting a mismatched hash never overwrites a different, \
        already-published, currently-valid generation that happens to share the same \
        content-addressed filename the mismatched call would have written under
        """
    )
    func setRejectingAMismatchedHashNeverClobbersAColludingExistingGeneration() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let genuinePayload = Data([9, 9, 9])
            try await cache.set(
                cacheKey,
                payload: genuinePayload,
                metadata: metadata(for: cacheKey, payload: genuinePayload)
            )

            // A second, unrelated call whose metadata falsely claims the
            // *first* payload's hash for *different* bytes: if `set` only
            // validated the hash's shape (not that it truly matches
            // `payload`), this would silently publish `otherPayload`'s bytes
            // under the filename the first, genuine generation already
            // owns, clobbering it.
            let otherPayload = Data([1, 2, 3])
            let collidingMetadata = metadata(for: cacheKey, payload: genuinePayload)
            await #expect(throws: AssetError.self) {
                try await cache.set(cacheKey, payload: otherPayload, metadata: collidingMetadata)
            }

            let fetched = try await cache.get(cacheKey)
            #expect(fetched?.payload == genuinePayload)
        }
    }
}
