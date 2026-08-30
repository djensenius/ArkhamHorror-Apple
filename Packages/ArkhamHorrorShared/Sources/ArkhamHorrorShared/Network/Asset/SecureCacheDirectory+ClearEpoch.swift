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
/// this file exists to prevent slip through undetected. This type instead
/// durably creates the counter file — atomically, with its initial value —
/// as part of ``SecureCacheDirectory/init(directory:fileManager:)`` itself
/// (see ``ensureClearEpochInitialized()``), strictly before any other
/// call on this instance can ever read or bump it. From that point on,
/// for the remaining lifetime of every
/// ``SecureCacheDirectory``/``AssetDiskCache`` ever constructed against
/// this directory, the file is guaranteed to already exist — so any
/// further "does not exist" result is no longer the safe pristine-root
/// case at all; it is unambiguous evidence the file was lost after
/// initialization, and is treated as a hard, typed, fail-closed failure
/// exactly like a corrupt/unparsable one, never as a fresh `0` baseline.
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

    /// Idempotently ensures this cache directory's durable clear-epoch
    /// counter file exists, initializing it to `0` ("never cleared") if
    /// it does not. Called exactly once, synchronously, as the final step
    /// of ``SecureCacheDirectory/init(directory:fileManager:)``,
    /// establishing the "always already exists past this point" invariant
    /// every later ``readPersistedClearEpoch()`` call relies on to treat
    /// a subsequent miss as a hard failure rather than a safe default.
    ///
    /// Deliberately does **not** require this instance's own
    /// cross-process ``acquireExclusiveLock()`` (which requires `async`,
    /// unavailable from a synchronous, throwing `init`): two processes
    /// racing to construct against the same brand-new directory for the
    /// first time could both observe "does not exist" and both attempt
    /// this same initializing write, but since both would write the
    /// exact identical initial content, and the final `rename` step is
    /// itself atomic at the filesystem level, this race is harmless
    /// regardless of which writer's `rename` lands last — there is no
    /// scenario in which racing initializers disagree on what value to
    /// initialize to.
    func ensureClearEpochInitialized() throws {
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
        try persistClearEpoch(0)
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
    @discardableResult
    func bumpClearEpoch() throws -> Int {
        let persisted = try readPersistedClearEpoch()
        guard persisted < Int.max else {
            throw AssetError.cachePersistenceFailed(
                "Clear-epoch counter is exhausted and cannot be durably distinguished further"
            )
        }
        let next = persisted + 1
        try persistClearEpoch(next)
        return next
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
