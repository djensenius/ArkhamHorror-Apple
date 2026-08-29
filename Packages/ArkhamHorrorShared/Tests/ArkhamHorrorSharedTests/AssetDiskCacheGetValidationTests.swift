@testable import ArkhamHorrorShared
import Foundation
import Testing

/// `get(_:)`'s pre-read metadata- and file-size-validation coverage for
/// ``AssetDiskCache``, split out of `AssetDiskCacheTests.swift` purely to
/// stay under SwiftLint's `type_body_length`.
extension AssetDiskCacheTests {
    @Test(
        """
        A clean miss (no metadata sidecar at all) returns nil without ever listing the cache \
        directory, so the common first-time-lookup case stays O(1) rather than paying an \
        O(n) directory-listing cost that only genuine corruption should incur
        """
    )
    func cleanMissNeverListsDirectoryButCorruptSidecarDoes() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let missingKey = try key("01001")

            // The very first call on a fresh instance also runs the
            // one-time `recoverOrphansIfNeeded()` startup sweep, which
            // legitimately lists the (here, empty) directory once; that
            // one call is not what this test is asserting against.
            let firstMiss = await cache.get(missingKey)
            #expect(firstMiss == nil)
            let callsAfterStartupSweep = await cache.directoryAccess.listNamesCallCount
            #expect(callsAfterStartupSweep >= 1)

            // A second clean miss, now that the one-time sweep has
            // already run: must not list the directory again at all.
            let secondMiss = await cache.get(missingKey)
            #expect(secondMiss == nil)
            let callsAfterSecondMiss = await cache.directoryAccess.listNamesCallCount
            #expect(callsAfterSecondMiss == callsAfterStartupSweep)

            // By contrast, a key whose sidecar exists but is undecodable
            // must fall through to the quarantine path, which does list
            // the directory (to sweep any other stale generation).
            let corruptKey = try key("01002")
            let metadataURL = directory.appendingPathComponent(
                "\(corruptKey.digestHex).meta.json"
            )
            try Data("not json".utf8).write(to: metadataURL)
            let corruptMiss = await cache.get(corruptKey)
            #expect(corruptMiss == nil)
            let callsAfterCorruptMiss = await cache.directoryAccess.listNamesCallCount
            #expect(callsAfterCorruptMiss > callsAfterStartupSweep)
        }
    }

    @Test(
        """
        Metadata claiming a negative encodedByteCount is quarantined without reading the payload
        """
    )
    func negativeEncodedByteCountQuarantinedWithoutReadingPayload() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            var json = try #require(
                try JSONSerialization
                    .jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
            )
            json["encodedByteCount"] = -1
            let tampered = try JSONSerialization.data(withJSONObject: json)
            try tampered.write(to: metadataURL)

            let fetched = await cache.get(cacheKey)
            #expect(fetched == nil)
        }
    }

    @Test(
        """
        Metadata claiming an encodedByteCount above the configured cap is quarantined without \
        reading the payload
        """
    )
    func oversizedEncodedByteCountQuarantinedWithoutReadingPayload() async throws {
        try await withScratchDirectory { directory in
            let limits = smallLimits()
            let cache = try AssetDiskCache(directory: directory, limits: limits)
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            var json = try #require(
                try JSONSerialization
                    .jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
            )
            json["encodedByteCount"] = limits.maxEncodedBytes + 1
            let tampered = try JSONSerialization.data(withJSONObject: json)
            try tampered.write(to: metadataURL)

            let fetched = await cache.get(cacheKey)
            #expect(fetched == nil)
        }
    }

    @Test(
        """
        An on-disk payload file larger than the configured cap is quarantined even when \
        metadata's own claimed size still passes
        """
    )
    func oversizedActualPayloadFileQuarantinedDespiteSmallClaimedSize() async throws {
        try await withScratchDirectory { directory in
            let limits = smallLimits()
            let cache = try AssetDiskCache(directory: directory, limits: limits)
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            // Substitute a payload file far larger than both the claimed
            // `encodedByteCount` (3 bytes) and the configured cap, without
            // touching the metadata sidecar at all.
            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: payload
            )
            let oversized = Data(repeating: 0xFF, count: limits.maxEncodedBytes + 1)
            try oversized.write(to: payloadURL)

            let fetched = await cache.get(cacheKey)
            #expect(fetched == nil)
        }
    }
}
