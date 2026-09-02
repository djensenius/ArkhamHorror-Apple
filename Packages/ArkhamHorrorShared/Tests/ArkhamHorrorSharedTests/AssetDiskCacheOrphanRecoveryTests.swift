@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Orphan-file and interrupted-write recovery coverage for
/// ``AssetDiskCache``, split out of `AssetDiskCacheTests.swift` (which
/// retains the shared `withScratchDirectory`/`key`/`metadata`/
/// `smallLimits`/`payloadFileURL` helpers) purely to stay under
/// SwiftLint's `type_body_length`, the same way `AssetDiskCacheAtomicityTests`
/// and `AssetDiskCacheTouchTests` are split by concern into their own files.
extension AssetDiskCacheTests {
    // MARK: - Orphan / temp-file recovery

    @Test("An orphaned payload file with no metadata sidecar is removed on first access")
    func orphanedPayloadWithoutMetadataRemoved() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: payload
            )
            try payload.write(to: payloadURL)

            // Any access triggers the once-per-instance orphan sweep.
            _ = try await cache.get(key("01002"))
            #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
        }
    }

    @Test("An orphaned metadata sidecar with no payload file is removed on first access")
    func orphanedMetadataWithoutPayloadRemoved() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            let payload = Data([1, 2, 3])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata(for: cacheKey, payload: payload)).write(to: metadataURL)

            _ = try await cache.get(key("01002"))
            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
        }
    }

    @Test("A leftover .tmp file from an interrupted write is removed on first access")
    func leftoverTempFileRemoved() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let tempURL = directory.appendingPathComponent("deadbeef.bin.tmp")
            try Data([1, 2, 3]).write(to: tempURL)

            _ = try await cache.get(key("01001"))
            #expect(!FileManager.default.fileExists(atPath: tempURL.path))
        }
    }
}
