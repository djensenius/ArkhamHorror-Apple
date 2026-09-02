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
    /// One-time-per-instance guard for ``recoverOrphansIfNeeded(forceRetry:)``'s
    /// own listing/reconciliation scan in ordinary steady-state operation
    /// — **but not unconditionally**: ``ensureRootAuthorityInitializedLocked()``
    /// always passes `forceRetry: true`, bypassing this flag entirely, so
    /// a failed best-effort removal (e.g. a transient fault) discovered
    /// while root authority has not yet successfully initialized is
    /// always retried on the next such call, rather than this flag
    /// permanently starving further attempts. Every other call site
    /// (notably ``get(_:)``'s read path) always passes the default
    /// `forceRetry: false`, preserving this flag's one-shot-per-instance
    /// contract there. See ``recoverOrphansIfNeeded(forceRetry:)``'s own
    /// doc comment for the full reasoning.
    var didRecoverOrphans = false

    /// One-time-per-instance guard for
    /// ``ensureRootAuthorityInitializedLocked()`` (see
    /// `AssetDiskCache+RootAuthority.swift`): cheap to skip once this
    /// instance has already confirmed the shared directory's root
    /// authority is initialized, at no cost to correctness (the underlying
    /// ``SecureCacheDirectory/ensureRootAuthorityInitializedLocked()`` is
    /// itself fully idempotent and safe to call unconditionally; this
    /// flag exists purely to avoid a redundant read on every single locked
    /// entry point for the remainder of this instance's lifetime).
    var didEnsureRootAuthorityInitialized = false

    /// This cache instance's live advisory owner marker, shared by all of
    /// its current issued operations. `locallyOpenIssuanceAuthorityIDs`
    /// distinguishes individual terminal/cancelled operations while this
    /// session remains live for sibling operations.
    var issuanceOwner: CacheIssuanceOwner?
    var locallyOpenIssuanceAuthorityIDs: Set<AuthorityID> = []

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

    /// Test-only hook invoked by ``removeIfApplied(_:token:)``
    /// immediately before *its own* call to
    /// ``SecureCacheDirectory/acquireExclusiveLock()`` — see that call
    /// site's doc comment. Always `nil` in production. A dedicated hook,
    /// separate from ``testOnlyPauseBeforeAcquiringWriteLock``, so a test
    /// can deterministically pause specifically a cancelled/superseded
    /// operation's own retraction — after
    /// ``AssetCacheService/markGenerationRetiring(_:for:)`` has already
    /// run (synchronously, strictly before this call) but strictly
    /// *before* this retraction's disk write has even begun — to prove
    /// that in-memory marker alone, with disk metadata still completely
    /// untouched, is what a concurrent reader's authority check must
    /// reject against, independent of and prior to any disk-side
    /// re-check.
    var testOnlyPauseBeforeAcquiringRemovalLock: (() async -> Void)?

    /// Test-only deterministic control over the authority-identifier
    /// source ``issueAuthorityLocked(for:)`` mints from -- inert in
    /// production (an empty queue and a zero failure count fall straight
    /// through to `SecRandomCopyBytes`), and deliberately *per-instance*
    /// rather than a process-wide global so one test's forced identifiers
    /// can never leak into an unrelated, concurrently-running cache. See
    /// ``AuthorityIDFaultInjectionState``, which mirrors
    /// ``FaultInjectionState``'s own lock-backed shape for the same
    /// reason.
    let authorityIDFaultState = AuthorityIDFaultInjectionState()

    init(directory: URL, limits: AssetCacheLimits, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.limits = limits
        self.fileManager = fileManager
        secureDirectory = try SecureCacheDirectory(directory: directory, fileManager: fileManager)
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
    /// own token compare-and-swap (see the type-level doc comment):
    /// returns ``AssetCacheService/MutationOutcome/stale`` (nothing
    /// written, no temp file even created) if a more-recently-issued
    /// token has already been applied for `key` — never a silent `Void`
    /// success a caller cannot distinguish from an actual write. A prior
    /// revision returned plain `Void` even on a CAS rejection, which let
    /// ``AssetCacheService/publish(_:asset:token:)`` believe its own
    /// write had landed purely because nothing was thrown, even though a
    /// completely independent sibling instance/process sharing this same
    /// directory had already durably won the write for this exact key —
    /// the disk-layer half of this cache's cross-process authority was
    /// silently discarded the instant it crossed this actor boundary.
    ///
    /// Rejects a `metadata.payloadSHA256Hex` that is not exactly 64
    /// lowercase hex characters before it is ever used to build a
    /// filename, and independently recomputes the hash from `payload`
    /// itself, rejecting a mismatch before writing anything — content-
    /// addressed filenames are only a valid substitute for a full
    /// integrity check as long as the name always matches the bytes
    /// stored under it.
    @discardableResult
    func set(
        _ key: AssetCacheKey,
        payload: Data,
        metadata: AssetCacheMetadata,
        token: AssetCacheService.CacheToken? = nil
    ) async throws -> AssetCacheService.MutationOutcome {
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
        return try setLocked(key, payload: payload, metadata: metadata, token: token)
    }

    private func setLocked(
        _ key: AssetCacheKey,
        payload: Data,
        metadata: AssetCacheMetadata,
        token: AssetCacheService.CacheToken?
    ) throws -> AssetCacheService.MutationOutcome {
        try ensureRootAuthorityInitializedLocked()
        try requireDiskWritesEnabledLocked()
        // Read once, under this already-held lock, and reused for
        // ``acceptToken(_:currentEpoch:currentIssued:)``'s compare: a
        // later re-read here could in principle observe a value a
        // *different* concurrent writer already changed, defeating the
        // whole point of holding this single exclusive lock across the
        // entire critical section. The applied disposition this write
        // itself commits (via
        // ``commitPublicationLocked(for:authorityID:contentHash:)``
        // below) is either `token`'s own already-accepted authority
        // identifier, reused verbatim, or (with no `token`) a freshly
        // minted one — never a function of this read.
        let currentEpoch = try secureDirectory.readPersistedClearEpoch()
        let currentRecord = try currentAuthorityRecordLocked(for: key)
        if let token {
            guard acceptToken(
                token,
                currentEpoch: currentEpoch,
                currentRecord: currentRecord
            ) else {
                return .stale
            }
        }
        guard Self.isValidContentHash(metadata.payloadSHA256Hex) else {
            throw AssetError.cachePersistenceFailed("payloadSHA256Hex is not a valid content hash")
        }
        guard AssetPayloadHasher.sha256Hex(payload) == metadata.payloadSHA256Hex else {
            throw AssetError.cachePersistenceFailed(
                "payloadSHA256Hex does not match the actual payload bytes"
            )
        }
        // Resolved exactly once and threaded through both the metadata
        // sidecar written below and this key's own disposition commit —
        // see ``resolvedMutationAuthorityLocked(for:token:)``'s own doc
        // comment for why re-deriving it a second time for one logical
        // write would desynchronize
        // ``AssetCacheMetadata/authorityIDAtPublication`` from the
        // disposition ``AssetDiskCache/get(_:)`` actually checks it
        // against.
        let authorityID = try resolvedMutationAuthorityLocked(for: key, token: token)
        var stampedMetadata = metadata
        stampedMetadata.authorityIDAtPublication = authorityID
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
        // `false` here means the metadata pointer rename itself already
        // succeeded (this generation is genuinely live) but the
        // confirming directory `fsync` did not -- see
        // ``commitMetadataPointerLocked(_:metadata:payloadName:payloadAlreadyExisted:)``'s
        // own doc comment for why that failure must still fall through
        // to the disposition commit below, only surfacing as a thrown
        // failure to *this* method's own caller afterward.
        let metadataPointerConfirmed = try commitMetadataPointerLocked(
            key,
            metadata: stampedMetadata,
            payloadName: payloadName,
            payloadAlreadyExisted: payloadAlreadyExisted
        )
        // Only after the payload is durably committed and the metadata
        // pointer rename has *at least* taken effect (whether or not its
        // own confirming fsync did): this key's durable applied
        // disposition must never advance past a mutation whose payload
        // write did not itself actually land, but must still advance for
        // one whose metadata pointer is already live, or that entry
        // would be made unreadable by ``AssetDiskCache/get(_:)``'s own
        // disposition cross-check for no reason. Commits the exact same
        // `authorityID` already stamped into `stampedMetadata` above
        // (never independently re-resolved) — see
        // ``resolvedMutationAuthorityLocked(for:token:)``'s own doc comment
        // for why conflating the two would break
        // ``removeIfApplied(_:token:)``'s exact-match retraction, and a
        // ``KeyDispositionKind/content`` disposition carrying this exact
        // payload's own hash, so a later `beginRevalidationIssuance` can
        // confirm the disposition is still genuinely live content, not a
        // since-retracted `.retiring`/`.tombstone` sharing the same
        // authority identifier.
        try commitPublicationLocked(
            for: key,
            authorityID: authorityID,
            contentHash: metadata.payloadSHA256Hex
        )
        guard metadataPointerConfirmed else {
            throw AssetError.cachePersistenceFailed(
                "metadata pointer committed but its directory fsync failed"
            )
        }
        return .applied
    }
}
