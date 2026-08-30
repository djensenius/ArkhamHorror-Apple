@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Atomic-write failure injection and restart-persistence coverage for
/// ``AssetDiskCache``, split out of `AssetDiskCacheTests.swift` (which
/// retains the shared `withScratchDirectory`/`key`/`metadata`/`smallLimits`
/// helpers) and `AssetDiskCacheQuotaTests.swift` (quota-eviction and
/// byte-accounting), purely to stay under SwiftLint's `file_length`.
extension AssetDiskCacheTests {
    // MARK: - Atomic failure injection

    @Test(
        "If the metadata write fails after the payload write succeeds, no orphaned payload remains"
    )
    func metadataWriteFailureLeavesNoOrphanPayload() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            await cache.directoryAccess.installFaultInjection(failSuffixes: [".meta.json"])
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])

            await #expect(throws: AssetError.self) {
                try await cache.set(
                    cacheKey,
                    payload: payload,
                    metadata: self.metadata(for: cacheKey, payload: payload)
                )
            }

            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: payload
            )
            #expect(
                !FileManager.default.fileExists(atPath: payloadURL.path),
                "A half-written entry (payload with no valid metadata) must not be left on disk"
            )
        }
    }

    @Test(
        """
        A failed initial temp-file write during atomicWrite removes the leftover .tmp file \
        immediately, even when that write already left a partially-written stub behind
        """
    )
    func failedTempFileWriteCleansUpTempFileImmediately() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            await cache.directoryAccess.installFaultInjection(failSuffixes: [".bin"])
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])

            await #expect(throws: AssetError.self) {
                try await cache.set(
                    cacheKey,
                    payload: payload,
                    metadata: self.metadata(for: cacheKey, payload: payload)
                )
            }

            let tempURL = payloadFileURL(directory: directory, cacheKey: cacheKey, payload: payload)
                .appendingPathExtension("tmp")
            #expect(
                !FileManager.default.fileExists(atPath: tempURL.path),
                """
                A stub left behind by a failed initial write must be removed as soon as that \
                write fails, not left for a future restart's orphan sweep
                """
            )
        }
    }

    @Test(
        """
        A failed rename during atomicWrite removes the leftover .tmp file immediately, \
        rather than leaving it for a future process restart's one-time orphan sweep
        """
    )
    func failedRenameCleansUpTempFileImmediately() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            await cache.directoryAccess.installFaultInjection(failSuffixes: [".bin"])
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])

            await #expect(throws: AssetError.self) {
                try await cache.set(
                    cacheKey,
                    payload: payload,
                    metadata: self.metadata(for: cacheKey, payload: payload)
                )
            }

            let tempURL = payloadFileURL(directory: directory, cacheKey: cacheKey, payload: payload)
                .appendingPathExtension("tmp")
            #expect(
                !FileManager.default.fileExists(atPath: tempURL.path),
                """
                The temp file must be removed as soon as the rename fails, not left for a \
                future restart's orphan sweep (which only runs once per cache instance)
                """
            )
        }
    }

    @Test(
        """
        If the metadata rename itself succeeds but the directory fsync that confirms its \
        durability fails, the just-published payload must NOT be deleted -- the metadata \
        pointer already, currently references it -- and a fresh instance reopening the same \
        directory afterward still finds a complete, consistent generation, never a dangling \
        metadata-to-missing-payload reference
        """
    )
    func metadataRenameSucceedsButDirectoryFsyncFailureNeverDeletesTheNewPayload() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            await cache.directoryAccess.installFaultInjection(
                failFsyncAfterRenameSuffixes: [".meta.json"]
            )
            let cacheKey = try key("01001")
            let payload = Data([9, 8, 7, 6])

            await #expect(throws: AssetError.self) {
                try await cache.set(
                    cacheKey,
                    payload: payload,
                    metadata: self.metadata(for: cacheKey, payload: payload)
                )
            }

            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: payload
            )
            #expect(
                FileManager.default.fileExists(atPath: payloadURL.path),
                """
                The metadata rename already succeeded (only its directory fsync was injected \
                to fail); the new payload it now references must never be deleted, or an \
                already-live reference would be broken immediately, not merely at some future \
                crash
                """
            )

            // A brand new instance reopening the same directory (as a
            // process restart would) must still see this exact,
            // consistent generation -- proving the failure was purely a
            // durability-confirmation gap, not a state-corrupting one.
            let reopened = try AssetDiskCache(directory: directory, limits: smallLimits())
            let recovered = try #require(try await reopened.get(cacheKey))
            #expect(recovered.payload == payload)
        }
    }

    @Test(
        """
        A metadata-commit failure while replacing an existing entry with a new generation \
        leaves the prior (still-valid) generation's payload and metadata completely intact
        """
    )
    func metadataReplaceFailureLeavesPriorGenerationIntact() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let firstPayload = Data([1, 1, 1, 1])
            try await cache.set(
                cacheKey,
                payload: firstPayload,
                metadata: metadata(for: cacheKey, payload: firstPayload)
            )
            let firstPayloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: firstPayload
            )

            // A metadata sidecar already exists for this key, so replacing
            // it with a second, different generation goes through
            // `FileManager.replaceItemAt`, an extension method on
            // `FileManager` that (unlike `moveItem`) cannot be overridden
            // by a `FileManager` subclass — a real filesystem failure is
            // injected instead, by removing write permission on the
            // directory so neither the new payload's nor the new
            // metadata's temp-file rename can complete.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: directory.path
            )
            let secondPayload = Data([2, 2, 2, 2])
            await #expect(throws: AssetError.self) {
                try await cache.set(
                    cacheKey,
                    payload: secondPayload,
                    metadata: self.metadata(for: cacheKey, payload: secondPayload)
                )
            }
            // Restore write permission before any further assertions (and
            // before `withScratchDirectory`'s own cleanup) so a failed
            // assertion here never leaves a permission-locked directory
            // behind.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )

            #expect(
                FileManager.default.fileExists(atPath: firstPayloadURL.path),
                "The prior generation's payload must survive a failed replace"
            )
            let secondPayloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: secondPayload
            )
            #expect(
                !FileManager.default.fileExists(atPath: secondPayloadURL.path),
                "A new generation's payload must not be orphaned if metadata never commits"
            )

            let fetched = try await cache.get(cacheKey)
            #expect(fetched?.payload == firstPayload, "The prior generation must still be servable")
        }
    }

    @Test(
        "A successful replace with a new generation removes the now-superseded prior payload"
    )
    func successfulReplaceRemovesSupersededPayload() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let firstPayload = Data([1, 1, 1, 1])
            try await cache.set(
                cacheKey,
                payload: firstPayload,
                metadata: metadata(for: cacheKey, payload: firstPayload)
            )
            let firstPayloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: firstPayload
            )

            let secondPayload = Data([2, 2, 2, 2])
            try await cache.set(
                cacheKey,
                payload: secondPayload,
                metadata: metadata(for: cacheKey, payload: secondPayload)
            )

            #expect(
                !FileManager.default.fileExists(atPath: firstPayloadURL.path),
                "The superseded generation's payload must be cleaned up after a successful replace"
            )
            let fetched = try await cache.get(cacheKey)
            #expect(fetched?.payload == secondPayload)
        }
    }

    @Test(
        """
        Startup recovery removes a payload orphaned by a crash between payload write and \
        metadata commit, without disturbing the currently-referenced generation
        """
    )
    func startupRecoveryRemovesOrphanedGenerationWithoutDisturbingCurrent() async throws {
        try await withScratchDirectory { directory in
            let cacheKey = try key("01001")
            let currentPayload = Data([3, 3, 3, 3])
            do {
                let firstInstance = try AssetDiskCache(directory: directory, limits: smallLimits())
                try await firstInstance.set(
                    cacheKey,
                    payload: currentPayload,
                    metadata: metadata(for: cacheKey, payload: currentPayload)
                )
            }
            // Simulate a crash right after a *would-be* replacement wrote
            // its new payload file but before its metadata pointer commit
            // — leave a stray, unreferenced payload file behind for this
            // same key.
            let orphanedPayload = Data([4, 4, 4, 4])
            let orphanedURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: orphanedPayload
            )
            try orphanedPayload.write(to: orphanedURL)

            let secondInstance = try AssetDiskCache(directory: directory, limits: smallLimits())
            let fetched = try await secondInstance.get(cacheKey)
            #expect(fetched?.payload == currentPayload, "The referenced generation must survive")
            #expect(
                !FileManager.default.fileExists(atPath: orphanedURL.path),
                "The unreferenced generation must be swept on startup"
            )
        }
    }
}
