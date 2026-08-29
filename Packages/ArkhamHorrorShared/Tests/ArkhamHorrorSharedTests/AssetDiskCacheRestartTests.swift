@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Restart-persistence, tampered-input rejection, and transient-failure
/// retry coverage for ``AssetDiskCache``, split out of
/// `AssetDiskCacheAtomicityTests.swift` purely to stay under SwiftLint's
/// `file_length` convention, reusing that file's (and
/// `AssetDiskCacheTests.swift`'s) shared helpers via the same
/// `extension AssetDiskCacheTests`.
extension AssetDiskCacheTests {
    @Test(
        """
        A tampered payloadSHA256Hex containing path-traversal or non-hex characters is \
        rejected before it can be used to construct a filesystem path
        """
    )
    func tamperedContentHashRejectedBeforePathConstruction() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            var tampered = metadata(for: cacheKey, payload: payload)
            tampered = AssetCacheMetadata(
                cacheKeyHex: tampered.cacheKeyHex,
                contentType: tampered.contentType,
                encodedByteCount: tampered.encodedByteCount,
                width: tampered.width,
                height: tampered.height,
                payloadSHA256Hex: "../../../../etc/passwd",
                etag: tampered.etag,
                lastModified: tampered.lastModified,
                resolvedURLString: tampered.resolvedURLString,
                insertedAt: tampered.insertedAt,
                accessSequence: tampered.accessSequence
            )

            await #expect(throws: AssetError.self) {
                try await cache.set(cacheKey, payload: payload, metadata: tampered)
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("etc/passwd").path
                )
            )
        }
    }

    @Test(
        "A restart (fresh actor over the same directory) still serves a previously stored entry"
    )
    func restartPersistsEntries() async throws {
        try await withScratchDirectory { directory in
            let cacheKey = try key("01001")
            let payload = Data([7, 7, 7, 7])
            do {
                let firstInstance = try AssetDiskCache(directory: directory, limits: smallLimits())
                try await firstInstance.set(
                    cacheKey,
                    payload: payload,
                    metadata: metadata(for: cacheKey, payload: payload)
                )
            }
            let secondInstance = try AssetDiskCache(directory: directory, limits: smallLimits())
            let fetched = await secondInstance.get(cacheKey)
            #expect(fetched?.payload == payload)
        }
    }

    @Test(
        "A transient directory-listing failure does not permanently disable orphan recovery"
    )
    func transientListingFailureRetriesOrphanRecoveryLater() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            // The very first `set` call's `recoverOrphansIfNeeded()` will
            // fail to list the directory exactly once, simulating a
            // transient I/O error rather than a permanent one.
            await cache.directoryAccess.installFaultInjection(listNamesFailuresRemaining: 1)

            let tempURL = directory.appendingPathComponent("deadbeef.bin.tmp")
            try Data([1, 2, 3]).write(to: tempURL)

            let cacheKey = try key("01001")
            let payload = Data([9, 9, 9])
            // First `set`: recovery attempt fails (listing throws), so the
            // orphan `.tmp` file is left untouched, but the entry itself
            // still writes successfully (recovery is a best-effort side
            // step, not a precondition for `set` to work).
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )
            #expect(
                FileManager.default.fileExists(atPath: tempURL.path),
                "The orphan must still be present after a failed recovery attempt"
            )

            // Second `set`: if `didRecoverOrphans` were wrongly latched
            // `true` after the earlier failed attempt, recovery would
            // never run again and the orphan would remain forever.
            let secondKey = try key("01002")
            let secondPayload = Data([4, 4, 4])
            try await cache.set(
                secondKey,
                payload: secondPayload,
                metadata: metadata(for: secondKey, payload: secondPayload)
            )
            #expect(
                !FileManager.default.fileExists(atPath: tempURL.path),
                "A retried recovery attempt must clean up the earlier orphan"
            )
        }
    }
}
