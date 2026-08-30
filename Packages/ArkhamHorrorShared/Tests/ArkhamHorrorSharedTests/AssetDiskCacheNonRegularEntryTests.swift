@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves ``AssetDiskCache`` never treats a symlink (or other non-regular
/// filesystem entry) occupying a payload/metadata name as if it were a
/// verified prior generation, split out of `AssetDiskCacheTests.swift`
/// (which retains the shared `withScratchDirectory`/`key`/`metadata`/
/// `smallLimits` helpers) purely to stay under SwiftLint's `file_length`.
///
/// Every case here targets one of five fixed suppressed-review findings:
/// `set(_:payload:metadata:)`'s rollback decision, `touch(_:metadata:)`'s
/// existence check, `removeAll()`'s listing-failure handling, startup
/// recovery's "is this payload name still referenced" check — all of which
/// previously accepted `attributes(name:) != nil` (true for a symlink)
/// where only `attributes(name:)?.isRegularFile == true` is trustworthy —
/// and `get(_:)`'s metadata read, which previously collapsed *every*
/// `SecureCacheDirectory.read` failure (including a thrown error for a
/// symlink or oversized sidecar, not only a clean `ENOENT` miss) into an
/// unquarantined miss.
extension AssetDiskCacheTests {
    /// Plants a symlink at `name` within `directory`, pointing at an
    /// unrelated file that is never itself a legitimate payload/metadata
    /// name this cache would create — mirroring the shape of an external
    /// tampering attempt or a confused prior process. The target file is
    /// deliberately created *inside* `directory` too (rather than some
    /// path outside the per-test scratch root), so it is swept up by
    /// `withScratchDirectory`'s own recursive cleanup: every operation
    /// under test here is descriptor-relative and `AT_SYMLINK_NOFOLLOW`
    /// regardless of where the symlink's target actually lives, so this
    /// choice does not weaken what the test proves.
    private func plantSymlink(named name: String, in directory: URL) throws {
        let target = directory.appendingPathComponent("outside-\(UUID().uuidString)")
        try Data("not a real cache entry".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(name),
            withDestinationURL: target
        )
    }

    @Test(
        """
        set(_:payload:metadata:) never mistakes a symlink already occupying the payload name \
        for a pre-existing generation: if the metadata commit then fails, the real payload it \
        just wrote (which replaced that symlink) is still rolled back rather than left as an \
        untracked orphan
        """
    )
    func setRollsBackRealPayloadThatReplacedASymlinkWhenMetadataCommitFails() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: payload
            )

            // A symlink — never a verified regular file — occupies the
            // exact name `set` is about to publish the real payload
            // under.
            try plantSymlink(named: payloadURL.lastPathComponent, in: directory)

            await cache.directoryAccess.installFaultInjection(failSuffixes: [".meta.json"])

            await #expect(throws: AssetError.self) {
                try await cache.set(
                    cacheKey,
                    payload: payload,
                    metadata: self.metadata(for: cacheKey, payload: payload)
                )
            }

            #expect(
                !FileManager.default.fileExists(atPath: payloadURL.path),
                """
                The real payload that replaced the planted symlink must still be rolled back: \
                treating the symlink as "already existed" would wrongly skip that cleanup and \
                leave an untracked, unevictable orphan
                """
            )
        }
    }

    @Test(
        """
        touch(_:metadata:) refuses a symlink occupying the payload name, matching a missing \
        payload
        """
    )
    func touchRefusesSymlinkOccupyingPayloadName() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: payload
            )
            try plantSymlink(named: payloadURL.lastPathComponent, in: directory)

            await #expect(throws: AssetError.self) {
                try await cache.touch(
                    cacheKey,
                    metadata: self.metadata(for: cacheKey, payload: payload)
                )
            }

            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            #expect(
                !FileManager.default.fileExists(atPath: metadataURL.path),
                "A refused touch must not publish a metadata sidecar pointing at a non-payload"
            )
        }
    }

    @Test(
        "removeAll() surfaces a directory-listing failure rather than silently reporting success"
    )
    func removeAllPropagatesListingFailureRatherThanReportingEmptySuccess() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            await cache.directoryAccess.installFaultInjection(listNamesFailuresRemaining: 1)

            await #expect(
                throws: AssetError.self,
                "A listing failure must be surfaced, never mistaken for \"the cache is empty\""
            ) {
                try await cache.removeAll()
            }

            // The entry written above must still be fully present and
            // servable: a caller that silently accepted "empty" success
            // here would wrongly believe the cache had actually been
            // cleared.
            let fetched = try await cache.get(cacheKey)
            #expect(fetched?.payload == payload)
        }
    }

    @Test(
        """
        Startup recovery quarantines a metadata sidecar whose referenced payload name is \
        occupied only by a symlink (never a verified regular file), rather than treating that \
        name as a legitimately referenced generation
        """
    )
    func recoveryQuarantinesMetadataReferencingASymlinkedPayloadName() async throws {
        try await withScratchDirectory { directory in
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: payload
            )
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")

            // Write a metadata sidecar exactly as `set` would, but replace
            // its referenced payload file with a symlink rather than the
            // real bytes — simulating external tampering or a payload
            // generation that was itself later replaced by a planted
            // symlink between two process runs.
            let sidecar = metadata(for: cacheKey, payload: payload)
            let data = try JSONEncoder.assetCache().encode(sidecar)
            try data.write(to: metadataURL)
            try plantSymlink(named: payloadURL.lastPathComponent, in: directory)

            // A fresh actor over the same directory triggers the one-time
            // startup orphan sweep on its first call.
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let fetched = try await cache.get(cacheKey)

            #expect(fetched == nil)
            #expect(
                !FileManager.default.fileExists(atPath: metadataURL.path),
                "Metadata referencing a non-regular \"payload\" must be quarantined, not trusted"
            )
        }
    }

    @Test(
        """
        get(_:) quarantines a symlink occupying the metadata sidecar's name, rather than \
        silently degrading to a miss and leaving it behind forever
        """
    )
    func getQuarantinesSymlinkOccupyingMetadataName() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            try plantSymlink(named: metadataURL.lastPathComponent, in: directory)

            let fetched = try await cache.get(cacheKey)

            #expect(fetched == nil)
            #expect(
                !FileManager.default.fileExists(atPath: metadataURL.path),
                """
                A read failure caused by something other than a clean ENOENT miss (here, a \
                symlink refused by O_NOFOLLOW) must quarantine the occupying entry rather than \
                merely returning a miss and leaving it in place to fail every future lookup
                """
            )
        }
    }

    @Test(
        """
        get(_:) quarantines a metadata sidecar larger than the bounded read cap, rather than \
        silently degrading to a miss and leaving it behind forever
        """
    )
    func getQuarantinesOversizedMetadataSidecar() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            let oversized = Data(repeating: 0x41, count: SecureCacheDirectory.maxMetadataBytes + 1)
            try oversized.write(to: metadataURL)

            let fetched = try await cache.get(cacheKey)

            #expect(fetched == nil)
            #expect(
                !FileManager.default.fileExists(atPath: metadataURL.path),
                """
                An oversized sidecar throws (rather than returning a clean miss) from the \
                bounded read, and must be quarantined rather than left to leak disk usage and \
                fail every future lookup for this key
                """
            )
        }
    }

    @Test(
        """
        removeAll() surfaces a failed final directory fsync as a failure, even when every \
        individual entry removal itself succeeded -- a caller must never believe a clear is \
        durably confirmed when the directory-entry updates behind it were not
        """
    )
    func removeAllSurfacesFsyncFailureEvenWhenEveryRemovalSucceeded() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            // No `remove(name:)` call is made to fail here at all: every
            // individual removal succeeds. Only the directory's own final
            // `fsync` -- confirming those removals are durable -- fails.
            await cache.directoryAccess.installFaultInjection(failNextRootFsyncCount: 1)

            await #expect(
                throws: AssetError.self,
                """
                A failed final directory fsync must be surfaced, never silently reported as a \
                fully successful, durable clear
                """
            ) {
                try await cache.removeAll()
            }
        }
    }
}
