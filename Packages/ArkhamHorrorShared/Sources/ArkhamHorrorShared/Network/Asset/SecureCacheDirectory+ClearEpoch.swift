import Foundation

/// A single, durable, cross-instance/cross-process "cache-wide clear
/// happened" epoch for one cache directory — the counterpart, for whole-
/// cache clears, that ``SecureCacheDirectory/allocateAccessSequence(atLeastAfter:)``
/// already provides for LRU ordering.
///
/// `AssetCacheService/globalGeneration` (see `AssetCacheService+Epoch.swift`)
/// already invalidates every in-process authority token the instant its own
/// ``AssetCacheService/evictAll()`` runs — but that counter lives purely in
/// one actor's own memory. Two independently-wired ``AssetCacheService``
/// instances sharing this same on-disk directory (two OS processes, or —
/// exactly as this package's own tests model it — two independently
/// constructed service instances in one process, each with its own private
/// ``AssetMemoryCache``) each keep their *own* private `globalGeneration`;
/// neither instance's clear ever bumps the other's. Without a durable,
/// shared signal, instance B's fetch — issued before instance A's
/// ``AssetCacheService/evictAll()``, but whose network response only
/// arrives (and is only ready to publish) *after* A's clear has already
/// returned — has no way to learn that a clear happened at all, and would
/// otherwise publish into (and serve straight from) its own untouched
/// memory cache as if nothing had happened, even though the shared cache
/// this directory represents was just told to forget everything.
///
/// This durable epoch closes that gap: every clear commits (write, `fsync`,
/// rename, directory `fsync`) a strictly higher epoch value here — durably,
/// under this directory's cross-process exclusive lock, and *before* any of
/// the clear's own destructive removal work begins (see
/// ``AssetDiskCache/removeAll()``) — and every authority token (see
/// ``AssetCacheService/CacheToken/durableClearEpoch``) captures the epoch
/// value observed at the moment it was issued. Every subsequent authority
/// re-check (``AssetCacheService/isAuthoritative(_:for:)`` and friends)
/// re-reads the *current* epoch and compares it against the value the
/// token captured at issuance — for *every* mutation this token might
/// eventually authorize, including a pure in-memory publish that never
/// itself touches disk on this instance — so an instance that never
/// otherwise learns about another instance's clear still cannot resurrect
/// or newly publish content across it.
///
/// **Durable initialization, not a fold-to-zero default.** A prior
/// revision of this type defaulted a missing file to epoch `0` ("never
/// cleared") for *any* `ENOENT`, on the theory that a freshly created
/// cache root simply has no file yet. That conflated two very different
/// situations that read identically from a bare existence check alone: a
/// genuinely pristine root that has never been opened before, and a root
/// whose durable counter file *existed* (recording one or more real
/// clears) but was since deleted, lost, or otherwise made unreadable —
/// silently reusing `0` for the latter would let a resurrection exactly
/// this file exists to prevent slip through undetected.
///
/// A *later* revision moved initialization into
/// ``SecureCacheDirectory/init(directory:fileManager:)`` itself, on the
/// theory that two racing initializers would always write the exact same
/// content and so no cross-process lock was needed. That reasoning holds
/// only while comparing two initializers racing *against each other* on a
/// root neither has ever touched before — it does not hold once a
/// *third* party (a real, already-completed ``AssetDiskCache/removeAll()``
/// durably bumping the epoch to a real, non-zero value) can interleave
/// between one racing initializer's own "does not exist" read and its own
/// unconditional "write `0`" step: that late writer's unconditional
/// `rename` would silently replace the just-committed, genuinely higher
/// epoch back down to `0`, resurrecting exactly the authority a clear that
/// already, durably happened was supposed to have revoked. Worse, that
/// same unconditional-write shape cannot tell "a genuinely pristine root"
/// apart from "a previously-initialized root whose counter file was later
/// lost" even with no racing initializer in the picture at all — both
/// look identical to a bare existence check taken at any single point in
/// time.
///
/// This revision closes both gaps at once, with two changes:
///
/// 1. Initialization is a genuine cross-process **locked** transaction —
///    see ``ensureRootAuthorityInitializedLocked()`` — run by every
///    ``AssetDiskCache`` locked entry point (never from
///    ``SecureCacheDirectory/init(directory:fileManager:)``, which cannot
///    itself acquire ``acquireExclusiveLock()`` since that is `async`).
///    While one process holds this directory's exclusive lock, no other
///    process can be inside this same transaction at all, eliminating the
///    write-after-read race entirely: a fresh clear can never land between
///    a racing initializer's own read and its own write, because both
///    steps now happen atomically with respect to every other holder of
///    this lock.
/// 2. A separate, permanent **root-init marker** file
///    (``rootInitMarkerFileName``) durably records "this root has been
///    initialized at least once, ever" — created together with, and only
///    together with, the epoch counter's very first value, and never
///    removed by anything (including a whole-cache
///    ``AssetDiskCache/removeAll()``) for the remaining lifetime of this
///    directory. A missing epoch counter is only ever treated as the safe
///    "genuinely pristine root" case when the marker is *also* missing;
///    if the marker exists but the counter does not, this root was
///    definitely initialized before and its counter was definitely lost
///    since — a hard, typed, fail-closed failure, never a silent
///    reinitialization to `0`.
extension SecureCacheDirectory {
    /// The fixed leaf name of this cache's durable clear-epoch counter
    /// file, inside the verified root directory. Not `private`, for the
    /// same reason as ``lockFileName``/``accessSequenceFileName``:
    /// ``AssetDiskCache/removeAll()`` must recognize and preserve this
    /// exact name across the very whole-cache clear it itself is used to
    /// record — deleting it during that same clear would silently reset
    /// every future reader back to "never cleared", exactly undoing the
    /// guarantee this file exists to provide.
    static let clearEpochFileName = ".arkham-cache.clear-epoch"

    /// Fixed-width (20-decimal-digit) encoding width for this file's
    /// value, mirroring ``AssetAccessSequence/digitWidth``'s identical
    /// rationale: a fixed serialized size regardless of the specific
    /// value, and one digit wider than ``AssetAccessSequence`` uses
    /// purely so `Int.max`'s 19-digit decimal representation always has
    /// at least one leading zero-pad digit to spare, keeping the exact
    /// same code path exercised for every value rather than only for
    /// ones that happen to need fewer digits.
    static let clearEpochDigitWidth = 20

    /// The fixed leaf name of this cache's permanent root-init marker
    /// file — see this file's type-level doc comment for exactly what it
    /// durably proves and why a separate file (rather than folding this
    /// into the epoch counter itself) is required. Not `private`, for the
    /// same reason as ``clearEpochFileName``: ``AssetDiskCache/removeAll()``
    /// must recognize and preserve this exact name across a whole-cache
    /// clear — this marker must never be removable by anything, ever, for
    /// the lifetime of this directory.
    static let rootInitMarkerFileName = ".arkham-cache.root-init"

    /// Idempotently ensures this cache directory's durable root authority
    /// — the root-init marker and the clear-epoch counter together — is
    /// fully initialized, as one cross-process locked transaction.
    ///
    /// **Must only ever be called while the caller already holds this
    /// instance's ``acquireExclusiveLock()``** — unlike the prior
    /// unlocked `ensureClearEpochInitialized()` this replaces, callers
    /// (every ``AssetDiskCache`` locked entry point) run this as the
    /// very first step of their own already-held critical section, before
    /// ``AssetDiskCache/recoverOrphansIfNeeded()`` and before any other
    /// read of the durable epoch — see
    /// `AssetDiskCache+RootAuthority.swift`'s call sites.
    ///
    /// Three cases, distinguished by the marker and counter's independent
    /// presence:
    ///
    /// - **Counter already exists.** Already initialized (by this
    ///   instance or any prior instance/process sharing this directory,
    ///   at any point in the past) — nothing to do, regardless of the
    ///   marker's own state. This is the overwhelmingly common case for
    ///   every call after the very first one against a given directory.
    /// - **Counter missing, marker exists.** This root was *definitely*
    ///   initialized before (the marker is only ever created together
    ///   with the counter's very first value, in the branch below, and
    ///   is never subsequently removed by anything) — so the counter's
    ///   current absence is definite evidence it was lost, deleted, or
    ///   corrupted away *after* initialization, never a safe "pristine
    ///   root" case. Fails closed with a typed, hard failure rather than
    ///   silently resetting authority back to `0` and potentially
    ///   resurrecting content a clear already durably revoked.
    /// - **Counter missing, marker missing.** As far as this locked
    ///   transaction can ever prove — no other process can be
    ///   concurrently inside this same method for this same directory
    ///   while this one holds the lock — this is genuinely the very first
    ///   time any process has ever initialized this root. Commits the
    ///   marker first, then the counter, both durably (write, `fsync`,
    ///   rename, directory `fsync`) before returning. A crash strictly
    ///   between the two leaves the marker installed and the counter
    ///   still missing, which the branch above then correctly refuses to
    ///   silently repair on any future open — requiring explicit,
    ///   deliberate intervention rather than an automatic, unaudited
    ///   reset of a root whose true prior history a crash mid-transaction
    ///   leaves genuinely unknowable.
    func ensureRootAuthorityInitializedLocked() throws {
        guard try read(name: Self.clearEpochFileName, maxBytes: Self.clearEpochDigitWidth) == nil
        else {
            // Already exists (whatever its content) -- never overwritten
            // here, even if it turns out to be unparsable: silently
            // resetting a file that already exists on the mere suspicion
            // it might be corrupt would risk clobbering a genuinely
            // higher, already-durable epoch this process simply failed to
            // parse for some unrelated, possibly transient reason.
            return
        }
        guard try read(name: Self.rootInitMarkerFileName, maxBytes: 1) == nil else {
            throw AssetError.clearFenceNotDurable(
                "Clear-epoch counter is missing on a previously initialized cache root; " +
                    "refusing to silently reinitialize its authority"
            )
        }
        do {
            let markerTempName = Self.rootInitMarkerFileName + ".tmp"
            try writeTempAndFsync(tempName: markerTempName, data: Data([0x01]))
            try renameAndFsyncDirectory(from: markerTempName, to: Self.rootInitMarkerFileName)
            try persistClearEpoch(0)
        } catch let error as AssetError {
            if case .clearFenceNotDurable = error {
                throw error
            }
            throw AssetError.clearFenceNotDurable(
                "Durable root-authority initialization failed: \(error)"
            )
        }
    }

    /// Reads the currently persisted clear-epoch value. Throws for *any*
    /// failure, including a clean "does not exist" miss -- see this
    /// type's own doc comment for why, once
    /// ``ensureClearEpochInitialized()`` has run (guaranteed by the time
    /// any ``SecureCacheDirectory`` instance is usable at all), a missing
    /// file can no longer be the safe "freshly created root" case and
    /// must instead be treated exactly like a corrupt/unparsable one:
    /// fail closed rather than silently grant a false "never cleared"
    /// baseline. ``AssetCacheService/currentDurableClearEpoch()``'s
    /// `try?` turns this throw into `nil`, and every authority check
    /// already treats `nil` as fail-closed ("not authoritative"/
    /// "changed").
    func readPersistedClearEpoch() throws -> Int {
        guard
            let data = try read(name: Self.clearEpochFileName, maxBytes: Self.clearEpochDigitWidth)
        else {
            throw AssetError.cachePersistenceFailed(
                "Clear-epoch file '\(Self.clearEpochFileName)' is missing after initialization"
            )
        }
        guard
            let string = String(data: data, encoding: .utf8),
            string.utf8.count == Self.clearEpochDigitWidth,
            string.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
            let parsed = Int(string)
        else {
            throw AssetError.cachePersistenceFailed(
                "Clear-epoch file '\(Self.clearEpochFileName)' is corrupt or unparsable"
            )
        }
        return parsed
    }

    /// Commits a strictly higher clear-epoch value than whatever is
    /// currently persisted, durably (write, `fsync`, rename, directory
    /// `fsync`), and returns the new value. Must only ever be called
    /// while the caller already holds this instance's
    /// ``acquireExclusiveLock()``, exactly like
    /// ``allocateAccessSequence(atLeastAfter:)``.
    ///
    /// ``AssetDiskCache/removeAll()`` calls this *before* any of its own
    /// destructive removal work begins: a caller must never be able to
    /// observe "the cache directory's entries are already gone" without
    /// also being able to observe "the durable clear epoch has already
    /// advanced past whatever any in-flight operation captured at
    /// issuance" — the reverse ordering (removal first, epoch bump second)
    /// would reopen exactly the race this type exists to close if a crash
    /// or failure landed between the two steps.
    ///
    /// **Terminal saturation, never silent reuse.** Once the persisted
    /// value is already `Int.max`, this throws rather than returning
    /// `Int.max` again: a prior revision instead silently re-returned the
    /// same saturated value forever once reached, which would let *two
    /// genuinely different* clears -- one whose token capture happened
    /// before the saturating bump, another happening after -- collapse
    /// onto the exact same epoch value and become indistinguishable to
    /// every downstream authority check, letting the earlier clear's own
    /// resurrection race slip through unnoticed. Failing closed instead
    /// (a value this many real clears reaching `Int.max` for one
    /// directory is not achievable in practice) preserves the invariant
    /// that every two clears this method ever successfully commits are
    /// always distinguishable.
    ///
    /// Every failure here — reading the current value, saturation, or
    /// the write/rename/`fsync` durably committing the new one — is
    /// surfaced as ``AssetError/clearFenceNotDurable(_:)`` specifically,
    /// never the generic ``AssetError/cachePersistenceFailed(_:)`` an
    /// ordinary best-effort disk I/O failure elsewhere in this package
    /// produces: see that case's own doc comment for why
    /// ``AssetDiskCache/removeAll()``'s caller
    /// (``AssetCacheService/evictAll()``) must be able to tell "the
    /// cross-instance/cross-process authority fence itself never
    /// durably advanced" apart from "the fence advanced fine, but some
    /// physical entry afterward could not be deleted" — the two demand
    /// entirely different handling, and folding both into the same
    /// error case would make that distinction unrecoverable by the time
    /// it reaches that caller.
    @discardableResult
    func bumpClearEpoch() throws -> Int {
        do {
            let persisted = try readPersistedClearEpoch()
            guard persisted < Int.max else {
                throw AssetError.clearFenceNotDurable(
                    "Clear-epoch counter is exhausted and cannot be durably distinguished further"
                )
            }
            let next = persisted + 1
            try persistClearEpoch(next)
            return next
        } catch let error as AssetError {
            if case .clearFenceNotDurable = error {
                throw error
            }
            throw AssetError.clearFenceNotDurable(
                "Durable clear-epoch bump failed: \(error)"
            )
        }
    }

    private func persistClearEpoch(_ epoch: Int) throws {
        precondition(epoch >= 0, "Clear epoch must never be negative, got \(epoch)")
        let tempName = Self.clearEpochFileName + ".tmp"
        let raw = String(epoch)
        let padded = String(repeating: "0", count: Self.clearEpochDigitWidth - raw.count) + raw
        try writeTempAndFsync(tempName: tempName, data: Data(padded.utf8))
        try renameAndFsyncDirectory(from: tempName, to: Self.clearEpochFileName)
    }
}
