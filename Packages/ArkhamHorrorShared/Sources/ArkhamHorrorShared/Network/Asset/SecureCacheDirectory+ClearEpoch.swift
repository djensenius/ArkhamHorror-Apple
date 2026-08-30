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

    /// Reads the currently persisted clear-epoch value, defaulting to `0`
    /// only for the one genuinely safe "never cleared" case: the file
    /// does not exist yet (a freshly created cache root). Throws for
    /// every other failure -- a read/verification error (wrong type,
    /// wrong owner, a bounded-read violation, a short read) or a parse
    /// failure (a corrupt or foreign file somehow planted at this exact
    /// name) -- rather than silently folding any of those into the same
    /// `0` baseline. Collapsing a genuine read failure into `0` would be
    /// actively unsafe, not merely imprecise: it would let this instance
    /// (wrongly) believe "no clear has ever happened" even though the
    /// durable counter it could not read might already record one or
    /// more clears, which is exactly the cross-instance resurrection
    /// this file exists to prevent. ``currentDurableClearEpoch()``'s
    /// `try?` turns this throw into `nil`, and every authority check
    /// already treats `nil` as fail-closed ("not authoritative"/
    /// "changed") -- so a read failure here correctly costs this
    /// instance its own authority rather than silently granting it a
    /// false "never cleared" baseline.
    func readPersistedClearEpoch() throws -> Int {
        guard let data = try read(name: Self.clearEpochFileName, maxBytes: 32) else {
            // A clean "does not exist yet" miss -- the one case where
            // baseline `0` is genuinely safe, not merely convenient.
            return 0
        }
        guard
            let string = String(data: data, encoding: .utf8),
            string.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
            !string.isEmpty,
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
    /// `fsync`) — the same crash-consistent write sequence
    /// ``writeTempAndFsync(tempName:data:)``/``renameAndFsyncDirectory(from:to:)``
    /// already provide for every other durable pointer in this package —
    /// and returns the new value. Must only ever be called while the
    /// caller already holds this instance's ``acquireExclusiveLock()``,
    /// exactly like ``allocateAccessSequence(atLeastAfter:)``.
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
    /// Saturates at `Int.max` rather than wrapping to a negative value on
    /// overflow, mirroring ``allocateAccessSequence(atLeastAfter:)``'s own
    /// identical rationale; once saturated, a further call simply returns
    /// `Int.max` again without rewriting the file (there is nothing higher
    /// to persist).
    @discardableResult
    func bumpClearEpoch() throws -> Int {
        let persisted = try readPersistedClearEpoch()
        if persisted >= Int.max {
            return Int.max
        }
        let next = persisted + 1
        try persistClearEpoch(next)
        return next
    }

    private func persistClearEpoch(_ epoch: Int) throws {
        let tempName = Self.clearEpochFileName + ".tmp"
        let data = Data(String(epoch).utf8)
        try writeTempAndFsync(tempName: tempName, data: data)
        try renameAndFsyncDirectory(from: tempName, to: Self.clearEpochFileName)
    }
}
