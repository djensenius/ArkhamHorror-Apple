@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Metadata-decode/accounting-quarantine and stranded-orphan-eviction
/// coverage for `AssetDiskCache`, split out of
/// `AssetDiskCacheQuotaTests.swift` (which retains the core LRU-eviction
/// and byte-accounting exactness tests) purely to stay under SwiftLint's
/// `file_length`.
extension AssetDiskCacheTests {
    @Test(
        """
        A corrupt (undecodable) metadata sidecar found during quota accounting is quarantined \
        immediately, not merely skipped, so it cannot occupy disk space indefinitely uncounted
        """
    )
    func undecodableEntryEncounteredDuringAccountingIsQuarantined() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: payload
            )
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            try Data("not json".utf8).write(to: metadataURL)

            // totalAccountedBytes() walks every entry via the same
            // internal accounting path evictIfNeeded() uses; it must not
            // count (and must actively remove) an entry whose sidecar
            // cannot be decoded.
            let total = await cache.totalAccountedBytes()
            #expect(total == 0)
            #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
        }
    }

    @Test(
        """
        An entry whose metadata cacheKeyHex does not match its own filename hash is quarantined \
        during quota accounting rather than silently skipped
        """
    )
    func mismatchedCacheKeyHexEncounteredDuringAccountingIsQuarantined() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: payload
            )
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            var json = try #require(
                try JSONSerialization
                    .jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
            )
            json["cacheKeyHex"] = "0000000000000000000000000000000000000000000000000000000000000000"
            let tampered = try JSONSerialization.data(withJSONObject: json)
            try tampered.write(to: metadataURL)

            let total = await cache.totalAccountedBytes()
            #expect(total == 0)
            #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
        }
    }

    @Test(
        """
        A failed publish whose own rolled-back payload also fails to be removed leaves a stray, \
        over-budget orphan that is accounted for -- and, if that alone breaches the high water \
        mark, disables further writes -- as part of that same failed call, rather than only being \
        discovered the next time some later, unrelated write happens to succeed
        """
    )
    func strandedOrphanFromFailedPublishIsAccountedBeforeAnyLaterCallEverRuns() async throws {
        try await withScratchDirectory { directory in
            // A tiny budget so a single 500-byte orphan alone already
            // exceeds the high water mark, with no other entry involved.
            let limits = AssetCacheLimits(
                maxEncodedBytes: 1_000_000,
                maxDimension: 8192,
                maxPixelCount: 32_000_000,
                memoryBudgetBytes: 100,
                diskBudgetBytes: 100
            )
            let cache = try AssetDiskCache(directory: directory, limits: limits)
            let firstKey = try key("01001")
            let firstPayload = Data(count: 500)

            // Force the metadata pointer commit to fail (its own temp
            // write never succeeds) *and* force the resulting rollback
            // removal of the just-written payload to also fail, so the
            // payload is left stranded on disk, referenced by no
            // metadata sidecar at all, exactly like a crash between the
            // payload write and a metadata commit that can never itself
            // be retried in place.
            await cache.directoryAccess.installFaultInjection(
                failSuffixes: [".meta.json"],
                failRemoveSuffixes: [".bin"]
            )

            await #expect(throws: (any Error).self) {
                try await cache.set(
                    firstKey,
                    payload: firstPayload,
                    metadata: metadata(for: firstKey, payload: firstPayload)
                )
            }

            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: firstKey,
                payload: firstPayload
            )
            #expect(
                FileManager.default.fileExists(atPath: payloadURL.path),
                "The rollback removal was itself made to fail, so the orphan must remain"
            )

            // Clear only the metadata-write fault before the second call
            // (that call's own metadata sidecar must be free to write
            // normally); deliberately keep the payload-removal fault
            // active so the first call's stranded orphan still cannot be
            // swept even if a later recovery pass tries -- proving the
            // second call is rejected purely because of accounting the
            // *first* call's own defer already performed, not because of
            // any fault of the second call's own.
            await cache.directoryAccess.installFaultInjection(failRemoveSuffixes: [".bin"])
            let secondKey = try key("01002")
            let secondPayload = Data(count: 1)

            // The first call's own failed publish must already have
            // accounted for -- and, since it alone breaches this tiny
            // budget's high water mark, durably disabled writes over --
            // the stranded orphan it left behind, entirely within that
            // one failing call. If eviction/accounting only ever ran
            // after a *successful* publish, this second, otherwise
            // perfectly normal write would wrongly succeed, silently
            // leaving physical usage over budget with no path back to
            // catching it.
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
