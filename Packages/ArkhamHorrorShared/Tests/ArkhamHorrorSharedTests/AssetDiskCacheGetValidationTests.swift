@testable import ArkhamHorrorShared
import Foundation
import Testing

/// `get(_:)`'s pre-read metadata- and file-size-validation coverage for
/// ``AssetDiskCache``, split out of `AssetDiskCacheTests.swift` purely to
/// stay under SwiftLint's `type_body_length`.
extension AssetDiskCacheTests {
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
