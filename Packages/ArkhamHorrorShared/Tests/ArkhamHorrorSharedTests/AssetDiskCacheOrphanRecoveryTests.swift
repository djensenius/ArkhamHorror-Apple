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

    @Test("Tokenless remove of a pristine key creates no authority record")
    func tokenlessRemoveOfPristineKeyCreatesNoAuthorityRecord() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let recordName = await cache.authorityRecordFilename(for: cacheKey)

            #expect(try await cache.remove(cacheKey) == .applied)

            #expect(
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(recordName).path
                )
            )
            let record = try await cache.currentKeyRecord(for: cacheKey)
            #expect(record == AssetDiskCache.KeyAuthorityRecord.pristine)
        }
    }

    @Test("Removing a key unlinks its deterministic payload without listing the directory")
    func removeUnlinksKnownPayloadWithoutDirectoryListing() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: payload
            )
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )
            let callsBeforeRemove = await cache.directoryAccess.listNamesCallCount

            try await cache.remove(cacheKey)

            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
            #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
            let callsAfterRemove = await cache.directoryAccess.listNamesCallCount
            #expect(callsAfterRemove == callsBeforeRemove)
        }
    }

    @Test("Payload orphans no longer listed by remove are swept by the next set")
    func removeDefersUndiscoverablePayloadOrphansToNextSetSweep() async throws {
        try await withScratchDirectory { directory in
            let cacheKey = try key("01001")
            let currentPayload = Data([1, 2, 3])
            let orphanPayload = Data([9, 9, 9, 9])
            let currentPayloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: currentPayload
            )
            let orphanPayloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: orphanPayload
            )

            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            try await cache.set(
                cacheKey,
                payload: currentPayload,
                metadata: metadata(for: cacheKey, payload: currentPayload)
            )
            // Simulate a crash-left generation for the same key after this
            // instance's set/eviction pass has already completed. Remove
            // will not enumerate the directory to discover this name.
            try orphanPayload.write(to: orphanPayloadURL)

            try await cache.remove(cacheKey)

            #expect(!FileManager.default.fileExists(atPath: currentPayloadURL.path))
            #expect(
                FileManager.default.fileExists(atPath: orphanPayloadURL.path),
                "Remove only unlinks hashes it can derive in O(1); orphan sweep owns strays"
            )

            let nextKey = try key("01003")
            let nextPayload = Data([4, 4, 4])
            try await cache.set(
                nextKey,
                payload: nextPayload,
                metadata: metadata(for: nextKey, payload: nextPayload)
            )
            #expect(!FileManager.default.fileExists(atPath: orphanPayloadURL.path))
        }
    }

    @Test("Payload orphans no longer listed by remove are swept by the next startup recovery")
    func removeDefersUndiscoverablePayloadOrphansToStartupRecovery() async throws {
        try await withScratchDirectory { directory in
            let cacheKey = try key("01001")
            let currentPayload = Data([1, 2, 3])
            let orphanPayload = Data([9, 9, 9, 9])
            let currentPayloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: currentPayload
            )
            let orphanPayloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: orphanPayload
            )

            do {
                let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
                try await cache.set(
                    cacheKey,
                    payload: currentPayload,
                    metadata: metadata(for: cacheKey, payload: currentPayload)
                )
                // Simulate a crash-left generation for the same key after this
                // instance's set/eviction pass has already completed. A remove
                // no longer enumerates the directory just to discover this name.
                try orphanPayload.write(to: orphanPayloadURL)

                try await cache.remove(cacheKey)

                #expect(!FileManager.default.fileExists(atPath: currentPayloadURL.path))
                #expect(
                    FileManager.default.fileExists(atPath: orphanPayloadURL.path),
                    "Remove only unlinks hashes it can derive in O(1); orphan sweep owns strays"
                )
            }

            let restarted = try AssetDiskCache(directory: directory, limits: smallLimits())
            let unrelatedKey = try key("01002")
            _ = try await restarted.get(unrelatedKey)
            #expect(!FileManager.default.fileExists(atPath: orphanPayloadURL.path))
        }
    }
}
