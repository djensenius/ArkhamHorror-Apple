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
            let fetched = try await secondInstance.get(cacheKey)
            #expect(fetched?.payload == payload)
        }
    }

    @Test(
        """
        A transient directory-listing failure fails the write closed, \
        but does not permanently disable orphan recovery once the fault clears
        """
    )
    func transientListingFailureRetriesOrphanRecoveryLater() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            // `recoverOrphansIfNeeded()`'s own listing (fault #1) fails
            // and durably disables writes; `requireDiskWritesEnabledLocked()`
            // then re-verifies the budget via `evictIfNeeded()`'s own
            // listing (fault #2), which also fails, so `set` throws
            // before ever writing a byte. Exactly two failures span the
            // entire first `set` call.
            await cache.directoryAccess.installFaultInjection(listNamesFailuresRemaining: 2)

            let tempURL = directory.appendingPathComponent("deadbeef.bin.tmp")
            try Data([1, 2, 3]).write(to: tempURL)

            let cacheKey = try key("01001")
            let payload = Data([9, 9, 9])
            // First `set`: recovery's listing fails, which must now
            // durably disable writes and fail this call closed -- an
            // unenumerable directory means physical usage cannot be
            // proven, so this call must never be allowed to silently
            // publish a new payload while that uncertainty stands.
            await #expect(throws: AssetError.self) {
                try await cache.set(
                    cacheKey,
                    payload: payload,
                    metadata: metadata(for: cacheKey, payload: payload)
                )
            }
            #expect(
                FileManager.default.fileExists(atPath: tempURL.path),
                "The orphan must still be present after a failed recovery attempt"
            )

            // Second `set`: the injected faults are now exhausted (the
            // transient error has cleared). If `didRecoverOrphans` were
            // wrongly latched `true` after the earlier failed attempt,
            // recovery would never run again and the orphan would remain
            // forever; if the disabled-writes marker were not re-checked
            // and cleared once a pass again proves the budget, this
            // second call would also wrongly stay disabled forever.
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

            let fetched = try await cache.get(secondKey)
            #expect(
                fetched?.payload == secondPayload,
                "Once the transient fault clears, writes must succeed normally again"
            )
        }
    }
}
