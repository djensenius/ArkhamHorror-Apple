import Foundation

/// An actor-isolated on-disk cache bounded by
/// ``AssetCacheLimits/diskBudgetBytes``, storing each entry as an immutable,
/// content-addressed payload file plus a versioned JSON metadata sidecar
/// (the sole mutable "pointer" for that key), addressed only through a
/// verified, descriptor-relative ``SecureCacheDirectory`` — never through
/// `FileManager`'s path-string APIs, which re-resolve every path component
/// (including any symlink) fresh on every call.
///
/// A replacement is never published by overwriting an existing payload file
/// in place: the new payload is written under its own filename (derived
/// from ``AssetCacheMetadata/payloadSHA256Hex``, never from the request
/// path), so it can never collide with — or destroy — the file a prior
/// generation's metadata still references. Every write that must survive a
/// crash follows one fixed order: write a bounded immutable temp file,
/// `fsync` it, rename it into place, `fsync` the containing directory —
/// first for the payload generation, then, only after that succeeds, for
/// the metadata pointer — and only once the pointer commit itself is
/// durable does this cache remove any now-superseded prior generation
/// (also followed by an `fsync`). A crash at any point before the pointer
/// rename's directory `fsync` returns leaves the previous, still-valid
/// generation completely untouched; a crash at any point after leaves the
/// new generation durably committed. Neither can ever observe a mixed or
/// half-written pair.
///
/// Metadata's actor-issued ``AssetCacheMetadata/accessSequence`` — never
/// filesystem `atime`, and never a wall-clock `Date` — is authoritative for
/// LRU. Corrupt entries (hash/size mismatch, undecodable or
/// version-mismatched metadata, or a `payloadSHA256Hex` that is not exactly
/// 64 lowercase hex characters — never trusted to build a filesystem path
/// unvalidated, since it is untrusted on-disk input) are quarantined
/// (deleted) on read rather than surfaced as valid data. Orphaned payload
/// files not referenced by any currently valid metadata sidecar (including
/// superseded generations left behind by a crash between a payload write
/// and its metadata pointer commit), metadata sidecars with no payload at
/// all, and any leftover `.tmp` file from an interrupted write, are
/// recovered (deleted) once at startup, without ever following a symlink
/// planted at any of those names.
///
/// A deletion that fails partway (e.g. a permission error) throws a typed
/// ``AssetError/cachePersistenceFailed(_:)`` rather than being silently
/// swallowed: the caller (``AssetCacheService``) maintains its own
/// in-memory tombstone for a key whose disk deletion could not be
/// confirmed, so a failed physical deletion can never let a subsequent
/// read resurrect the bytes it was supposed to invalidate.
actor AssetDiskCache {
    let directory: URL
    let limits: AssetCacheLimits
    let fileManager: FileManager
    let secureDirectory: SecureCacheDirectory
    var didRecoverOrphans = false
    var accessSequenceAllocator = AssetAccessSequenceAllocator()

    /// This actor's own independent half of the token compare-and-swap
    /// described in `AssetCacheService+Epoch.swift` and mirrored by
    /// ``AssetMemoryCache``'s identical `appliedToken`/`acceptedGeneration`
    /// pair (see that type's doc comment for why this actor needs its own
    /// copy rather than relying solely on `AssetCacheService`'s own
    /// re-checks: actor call scheduling order is not guaranteed to match
    /// issuance order).
    var appliedToken: [AssetCacheKey: AssetCacheService.CacheToken] = [:]
    var acceptedGeneration = 0

    /// Test-only hook invoked by ``get(_:)`` immediately before it returns
    /// a successfully-validated hit — see that call site's doc comment.
    /// Always `nil` in production; a test installs a closure here to pause
    /// a disk read mid-flight and deterministically race another
    /// operation against it.
    var testOnlyPauseBeforeReturningHit: (() async -> Void)?

    init(directory: URL, limits: AssetCacheLimits, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.limits = limits
        self.fileManager = fileManager
        secureDirectory = try SecureCacheDirectory(directory: directory, fileManager: fileManager)
    }

    /// Test-only: installs ``testOnlyPauseBeforeReturningHit``. A plain
    /// actor-isolated method (rather than exposing the stored property for
    /// direct external assignment) so a test's call site reads as an
    /// ordinary, obviously-`await`-requiring actor call.
    func installTestOnlyPauseBeforeReturningHit(_ pause: @escaping () async -> Void) {
        testOnlyPauseBeforeReturningHit = pause
    }

    /// The default production cache directory: a versioned subdirectory of
    /// the platform caches directory, so a future breaking layout change
    /// can ship as a new version directory without needing bespoke
    /// migration of the old one (out of scope per the issue's non-scope
    /// list; the old directory is simply abandoned and reclaimed by the OS
    /// or manual cleanup).
    static func productionDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw AssetError.cachePersistenceFailed("No caches directory available")
        }
        return base.appendingPathComponent("ArkhamHorrorAssets", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    /// Publishes `payload` under `metadata`'s key as a new, immutable,
    /// content-addressed generation, then atomically commits the metadata
    /// "pointer" to it, per the crash-consistency contract documented on
    /// this type. Stamps a freshly allocated ``AssetCacheMetadata/accessSequence``
    /// into `metadata` before persisting it, superseding whatever value
    /// the caller passed in — this cache's own counter is always
    /// authoritative for order among the entries *it* persists.
    ///
    /// `token`, when supplied, gates the entire write behind this actor's
    /// own token compare-and-swap (see the type-level doc comment): a
    /// silent no-op (nothing written, no temp file even created) if a
    /// more-recently-issued token has already been applied for `key`.
    ///
    /// Rejects a `metadata.payloadSHA256Hex` that is not exactly 64
    /// lowercase hex characters before it is ever used to build a
    /// filename, and independently recomputes the hash from `payload`
    /// itself, rejecting a mismatch before writing anything — content-
    /// addressed filenames are only a valid substitute for a full
    /// integrity check as long as the name always matches the bytes
    /// stored under it.
    func set(
        _ key: AssetCacheKey,
        payload: Data,
        metadata: AssetCacheMetadata,
        token: AssetCacheService.CacheToken? = nil
    ) async throws {
        // The entire write (orphan recovery, payload publish, metadata
        // pointer commit, superseded-generation cleanup, and eviction) runs
        // inside one cross-process/cross-instance exclusive lock (see
        // ``SecureCacheDirectory/acquireExclusiveLock()``): every step
        // here is synchronous Darwin I/O with no further `await`, so once
        // the lock is held, the whole critical section runs to completion
        // without ever suspending this actor mid-section. This is the sole
        // caller that acquires it for a write; nothing this critical
        // section calls (including `recoverOrphansIfNeeded`/
        // `evictIfNeeded`) acquires it again, since `flock` is not
        // reentrant across separate opens of the same lock file even
        // within one process. The lock is acquired and its critical
        // section run directly on this actor's own executor (never via a
        // closure passed into `secureDirectory`) so Swift's actor
        // isolation guarantee — resuming this method back on the actor's
        // own executor after its own `await` — actually applies; see that
        // method's doc comment for why a closure-based API cannot offer
        // the same guarantee.
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try setLocked(key, payload: payload, metadata: metadata, token: token)
    }

    private func setLocked(
        _ key: AssetCacheKey,
        payload: Data,
        metadata: AssetCacheMetadata,
        token: AssetCacheService.CacheToken?
    ) throws {
        recoverOrphansIfNeeded()
        if let token, !acceptToken(token, for: key) {
            return
        }
        // The durable half of the write CAS (see
        // `AssetDiskCache+Generation.swift`): rejects this write as a
        // stale no-op if some other write -- in this process or another
        // -- has already been durably committed for this key since
        // `token` captured its baseline.
        if let token, !acceptDurableGeneration(token, for: key) {
            return
        }
        guard Self.isValidContentHash(metadata.payloadSHA256Hex) else {
            throw AssetError.cachePersistenceFailed("payloadSHA256Hex is not a valid content hash")
        }
        guard AssetPayloadHasher.sha256Hex(payload) == metadata.payloadSHA256Hex else {
            throw AssetError.cachePersistenceFailed(
                "payloadSHA256Hex does not match the actual payload bytes"
            )
        }
        let payloadName = payloadFilename(
            keyHash: key.digestHex,
            contentHash: metadata.payloadSHA256Hex
        )
        // Only a verified *regular* file at this name counts as "already
        // existed" for rollback purposes. A symlink or other non-regular
        // entry occupying this name is never a payload a surviving prior
        // generation could depend on — if this call's own write later
        // fails to commit (the metadata pointer step below), the
        // just-written real payload must still be rolled back rather than
        // mistaken for pre-existing data it must not touch, or it would
        // be left as an untracked, unevictable orphan until the next
        // startup's orphan sweep.
        let payloadAlreadyExisted =
            (try? secureDirectory.attributes(name: payloadName))?.isRegularFile == true

        try writePayloadGenerationLocked(payloadName: payloadName, payload: payload)
        try commitMetadataPointerLocked(
            key,
            metadata: metadata,
            payloadName: payloadName,
            payloadAlreadyExisted: payloadAlreadyExisted
        )
        evictIfNeeded()
    }

    /// Updates only the metadata sidecar for an already-cached `key` (for
    /// example bumping ``AssetCacheMetadata/accessSequence`` after a 304
    /// revalidation), without re-writing the unchanged payload file.
    /// Throws if no payload currently exists on disk matching
    /// `metadata.payloadSHA256Hex`, so this can never create an orphaned
    /// metadata-only entry. `token`, when supplied, gates this the same
    /// way as ``set(_:payload:metadata:token:)``.
    func touch(
        _ key: AssetCacheKey,
        metadata: AssetCacheMetadata,
        token: AssetCacheService.CacheToken? = nil
    ) async throws {
        // Same single-top-level-lock convention as ``set(_:payload:metadata:token:)``.
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try touchLocked(key, metadata: metadata, token: token)
    }

    private func touchLocked(
        _ key: AssetCacheKey,
        metadata: AssetCacheMetadata,
        token: AssetCacheService.CacheToken?
    ) throws {
        recoverOrphansIfNeeded()
        if let token, !acceptToken(token, for: key) {
            return
        }
        // Same durable CAS as ``setLocked(_:payload:metadata:token:)`` --
        // see that call site's comment and `AssetDiskCache+Generation.swift`.
        // A touch never itself advances the durable write-generation (it
        // republishes no new content), so this only ever rejects a touch
        // whose baseline has been superseded by some other key-changing
        // write since it was issued.
        if let token, !acceptDurableGeneration(token, for: key) {
            return
        }
        guard Self.isValidContentHash(metadata.payloadSHA256Hex) else {
            throw AssetError.cachePersistenceFailed("payloadSHA256Hex is not a valid content hash")
        }
        let payloadName = payloadFilename(
            keyHash: key.digestHex,
            contentHash: metadata.payloadSHA256Hex
        )
        // A symlink or other non-regular entry at this name is never a
        // verified payload to touch: publishing a metadata sidecar that
        // points at it would let a later read quarantine the mismatch,
        // but only after having already accepted a bogus pointer as if it
        // were a legitimate revalidation. Require a verified regular file
        // before committing the metadata bump.
        guard (try? secureDirectory.attributes(name: payloadName))?.isRegularFile == true else {
            throw AssetError.cachePersistenceFailed("No cached payload to touch for this key")
        }
        var stamped = metadata
        stamped.accessSequence = accessSequenceAllocator.allocate()
        // Re-stamped from this actor's own fresh read, exactly like
        // ``accessSequence`` above -- never trusted from whatever value
        // the caller's `metadata` happened to carry (e.g. a value read
        // into memory before some intervening disk write). By this point
        // ``acceptDurableGeneration(_:for:)`` above has already confirmed
        // this equals `token.diskBaselineGeneration` when a token was
        // supplied, so this is a same-value re-affirmation in that case,
        // and the sole source of truth when no token gates this call.
        stamped.writeGeneration = currentWriteGenerationLocked(for: key)
        do {
            try persistMetadata(stamped, name: metadataFilename(for: key))
        } catch {
            throw AssetError.cachePersistenceFailed(String(describing: error))
        }
    }

    // MARK: - Names

    /// The filename for `key`'s payload under `contentHash` — the caller
    /// must have already validated `contentHash` via
    /// ``isValidContentHash(_:)`` if it did not originate from a value
    /// this cache computed itself (e.g. it was read back from an on-disk
    /// metadata sidecar). Deliberately key-local (built only from a
    /// validated key hash and a validated content hash, never from any
    /// other input) and free of any path separator, so it is always a
    /// single, traversal-proof leaf name inside the verified cache
    /// directory — never a relative or absolute path segment.
    func payloadFilename(keyHash: String, contentHash: String) -> String {
        "\(keyHash).\(contentHash).bin"
    }

    func metadataFilename(for key: AssetCacheKey) -> String {
        "\(key.digestHex).meta.json"
    }

    // MARK: - Token CAS

    /// only if its generation is not older than the generation this actor
    /// currently accepts writes under, and it is strictly newer than
    /// whatever token this actor last recorded as applied for `key` (a
    /// `nil` prior value always accepts). Records `token` as the new
    /// applied value on acceptance so a subsequent, older-issued token for
    /// the same key can never later overwrite it. Mirrors
    /// ``AssetMemoryCache``'s identical private helper of the same name.
    /// Not `private`: also called from `AssetDiskCache+Removal.swift`'s
    /// `remove(_:token:)`/`removeAll()`, in the same file-length budget
    /// as this type.
    func acceptToken(
        _ token: AssetCacheService.CacheToken,
        for key: AssetCacheKey
    ) -> Bool {
        guard token.generation >= acceptedGeneration else { return false }
        if let applied = appliedToken[key], applied >= token {
            return false
        }
        appliedToken[key] = token
        return true
    }

    /// `true` only for a string that is exactly 64 lowercase ASCII hex
    /// characters — the shape of a real SHA-256 hex digest, and the only
    /// shape ever safe to interpolate into a filesystem path derived from
    /// otherwise-untrusted on-disk metadata. In particular this rejects
    /// `/`, `..`, and any other path-traversal or delimiter-injection
    /// attempt a tampered metadata sidecar's `payloadSHA256Hex` field could
    /// otherwise smuggle into ``payloadFilename(keyHash:contentHash:)``.
    static func isValidContentHash(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
        }
    }
}

/// Not `private`: `AssetDiskCache+Recovery.swift` also decodes metadata
/// sidecars with this exact configuration during startup recovery.
///
/// A fresh instance per call, rather than a shared singleton, since
/// `JSONEncoder`/`JSONDecoder` are not documented as thread-safe for
/// concurrent `encode`/`decode` calls: multiple `AssetDiskCache` actor
/// instances (or concurrently running tests) could otherwise race on one
/// shared encoder/decoder's internal state. Constructing one is cheap
/// (only setting a date strategy), so this costs nothing meaningful per
/// call.
extension JSONEncoder {
    static func assetCache() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static func assetCache() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
