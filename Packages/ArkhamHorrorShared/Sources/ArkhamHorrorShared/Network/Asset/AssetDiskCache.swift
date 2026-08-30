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
/// in-memory, best-effort tombstone for a key whose disk deletion could
/// not be confirmed. That in-process tombstone is purely an optimization
/// (skip a disk read this process already expects to be pointless), never
/// a durable, cross-process, or cross-restart correctness guarantee: any
/// disk-only hit — from this cache or a fresh instance in a different
/// process/restart — is only ever trusted by ``AssetCacheService`` after
/// it independently passes a fresh online conditional (`ETag`/
/// `Last-Modified`) revalidation against the live server. That single
/// requirement is what actually prevents a failed local deletion (or any
/// other cross-process disk-state race) from ever resurrecting content
/// the origin itself considers gone or changed — not a durable per-key
/// tombstone or whole-cache "reads disabled" marker file.
actor AssetDiskCache {
    let directory: URL
    let limits: AssetCacheLimits
    let fileManager: FileManager
    let secureDirectory: SecureCacheDirectory
    var didRecoverOrphans = false

    /// This process's own in-memory fail-closed half of the disk-writes-
    /// disabled marker (see `AssetDiskCache+Tombstone.swift`'s type-level
    /// doc comment). Set to `true` *before* ``markDiskWritesDisabledLocked()``
    /// even attempts its own durable marker write/rename, so a failure to
    /// commit that marker durably still leaves *this* actor instance
    /// disabled for the remainder of its lifetime -- a lost marker commit
    /// must never silently fail open back to "writes enabled" purely
    /// because the durable write it was attempting itself failed. Cleared
    /// only by ``clearDiskWritesDisabledLocked()``, and only once *both*
    /// the durable marker removal and its directory `fsync` have
    /// themselves succeeded -- never merely because a caller believes
    /// conditions have improved.
    var writesDisabledLocal = false

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

    /// Test-only hook invoked by ``set(_:payload:metadata:token:)``
    /// immediately before *its own* call to
    /// ``SecureCacheDirectory/acquireExclusiveLock()`` — see that call
    /// site's doc comment. Always `nil` in production. Deliberately
    /// separate from ``testOnlyPauseBeforeReturningHit``: a durable-clear-
    /// epoch read (``AssetCacheService/currentDurableClearEpoch()``) also
    /// acquires this same directory's exclusive lock, one or more times,
    /// *before* a fetch ever reaches this write — so a test that wants to
    /// deterministically race another in-process caller specifically
    /// against *this* write's own lock acquisition (rather than against
    /// whichever earlier epoch read happens to contend first) must anchor
    /// on this hook, not on any earlier read-side one.
    var testOnlyPauseBeforeAcquiringWriteLock: (() async -> Void)?

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

    /// Test-only: installs ``testOnlyPauseBeforeAcquiringWriteLock``. See
    /// ``installTestOnlyPauseBeforeReturningHit(_:)`` for the rationale
    /// behind exposing this as a method rather than a settable property.
    func installTestOnlyPauseBeforeAcquiringWriteLock(_ pause: @escaping () async -> Void) {
        testOnlyPauseBeforeAcquiringWriteLock = pause
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
        if let pause = testOnlyPauseBeforeAcquiringWriteLock {
            await pause()
        }
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
        try requireDiskWritesEnabledLocked()
        if let token, !acceptToken(token, for: key) {
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

        // `evictIfNeeded()` is this cache's sole "prove the budget" pass:
        // it re-lists the directory, sweeps every orphan/stray byte it
        // can find, and durably disables further writes if usage cannot
        // be proven within budget. It must run after *every* attempted
        // publish here — not only a fully successful one — because a
        // failure partway through `writePayloadGenerationLocked` or
        // `commitMetadataPointerLocked` (for example, a rolled-back
        // payload whose own best-effort removal itself fails) can leave
        // stray bytes on disk that this call itself just created. Without
        // this `defer`, those bytes would sit completely unaccounted
        // against the quota — and any over-budget condition they cause
        // completely unenforced — until some unrelated *future*
        // successful `set` happened to run eviction again. Running it
        // unconditionally here means a failed publish's own mess is
        // priced in and, if it pushes usage out of bounds, immediately
        // fail-closes further writes rather than leaving that window
        // open indefinitely.
        defer { evictIfNeeded() }
        try writePayloadGenerationLocked(payloadName: payloadName, payload: payload)
        try commitMetadataPointerLocked(
            key,
            metadata: metadata,
            payloadName: payloadName,
            payloadAlreadyExisted: payloadAlreadyExisted
        )
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
        //
        // Deliberately a distinct, typed case
        // (``AssetError/entryNoLongerCachedToTouch``) rather than the
        // generic ``AssetError/cachePersistenceFailed(_:)`` used
        // elsewhere in this method: a missing payload here is not a mere
        // I/O hiccup a caller may treat as best-effort/non-fatal — it is
        // definitive proof that some other, more-recently-concluded
        // operation for this exact key (a definitive 404 invalidation, a
        // fresh publish under new content whose own commit already
        // cleaned up this generation, or a whole-cache clear) already
        // removed this entry from the *shared* disk cache. A caller
        // (``AssetCacheService/touch(_:asset:token:)``) that already
        // wrote this same revalidation into its own *private* in-memory
        // cache under this same token must retract that write rather
        // than treat this as recoverable — otherwise memory alone could
        // go on serving stale bytes the shared disk has already disowned,
        // indefinitely, regardless of what any other cache instance
        // sharing this directory has since done.
        guard (try? secureDirectory.attributes(name: payloadName))?.isRegularFile == true else {
            throw AssetError.entryNoLongerCachedToTouch
        }
        var stamped = metadata
        // See ``SecureCacheDirectory/allocateAccessSequence(atLeastAfter:)``'s
        // doc comment: `metadata.accessSequence` here is this exact
        // entry's own previously-known value (as most recently observed
        // by whichever caller is now touching it), folded in purely as an
        // extra floor for a freshly created cache root whose durable
        // counter file does not exist yet — the counter file itself is
        // always authoritative once it exists.
        stamped.accessSequence = try secureDirectory.allocateAccessSequence(
            atLeastAfter: metadata.accessSequence
        )
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
}
