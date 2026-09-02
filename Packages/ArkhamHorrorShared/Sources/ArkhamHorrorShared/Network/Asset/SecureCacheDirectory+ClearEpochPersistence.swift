import Foundation

/// Persisted clear-epoch counter read/write helpers for
/// ``SecureCacheDirectory``, split out of
/// `SecureCacheDirectory+ClearEpoch.swift` purely to keep that
/// file within this package's `file_length` limit -- these two
/// files together implement one cohesive clear-epoch subsystem;
/// this half owns the durable counter's own read/bump/persist
/// mechanics once root-authority initialization (the other half)
/// has already guaranteed a valid epoch exists.
extension SecureCacheDirectory {
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

    func persistClearEpoch(_ epoch: Int) throws {
        precondition(epoch >= 0, "Clear epoch must never be negative, got \(epoch)")
        let tempName = Self.clearEpochFileName + ".tmp"
        let raw = String(epoch)
        let padded = String(repeating: "0", count: Self.clearEpochDigitWidth - raw.count) + raw
        try writeTempAndFsync(tempName: tempName, data: Data(padded.utf8))
        try renameAndFsyncDirectory(from: tempName, to: Self.clearEpochFileName)
    }

    /// Durably commits the permanent root-init marker file (write,
    /// `fsync`, rename, directory `fsync`) — idempotent to call again if
    /// it already exists (a plain overwrite-with-identical-content), so
    /// callers never need to re-check existence immediately beforehand
    /// themselves.
    func installRootInitMarkerLocked() throws {
        let markerTempName = Self.rootInitMarkerFileName + ".tmp"
        try writeTempAndFsync(tempName: markerTempName, data: Data([0x01]))
        try renameAndFsyncDirectory(from: markerTempName, to: Self.rootInitMarkerFileName)
    }

    /// Durably commits the root-freshness witness file (write, `fsync`,
    /// rename, directory `fsync`) under this directory's already-held
    /// cross-process lock — the durable retry point for the best-effort,
    /// unlocked write ``installRootFreshnessWitnessBestEffort()`` attempts
    /// from `init`. Idempotent, exactly like ``installRootInitMarkerLocked()``.
    func installRootFreshnessWitnessLocked() throws {
        let witnessTempName = Self.rootFreshnessWitnessFileName + ".tmp"
        try writeTempAndFsync(tempName: witnessTempName, data: Data([0x01]))
        try renameAndFsyncDirectory(from: witnessTempName, to: Self.rootFreshnessWitnessFileName)
    }

    /// Durably consumes (removes, then `fsync`s the directory entry
    /// mutation) the root-freshness witness file — see
    /// `SecureCacheDirectory+ClearEpoch.swift`'s type-level doc comment
    /// for why this witness must become a one-shot token, never a
    /// permanent freshness proof: once this root's real authority (the
    /// clear-epoch counter and its root-init marker) is durably
    /// established, the witness's only job is already done, and letting
    /// it persist forever afterward is exactly what would let a *later*,
    /// otherwise-unrelated loss of both authority files wrongly resurrect
    /// "pristine root" treatment for a root that has since been through
    /// one or more real clears.
    ///
    /// Idempotent: tolerates the witness already being absent (a clean
    /// `ENOENT` from ``remove(name:)``) as success, never an error — this
    /// is called unconditionally, on every single locked authority check
    /// for the remaining lifetime of an already-initialized root (see
    /// ``ensureRootAuthorityInitializedLockedUnwrapped(isSurvivingEntryAcceptable:)``'s
    /// "counter exists" branch), so it must be cheap and safe to call
    /// redundantly, including after a crash left a prior call to this
    /// same method only partially complete.
    ///
    /// Must only ever be called *after* this transaction's own
    /// authority-establishing writes (the epoch counter and the root-init
    /// marker) have already durably committed — never before. Removing
    /// this witness first and only afterward committing the epoch/marker
    /// would, if a crash landed in between, permanently strip an
    /// otherwise still-genuinely-pristine root of its only remaining
    /// freshness proof, bricking it exactly like a marker-before-epoch
    /// crash already does for the counter/marker pair themselves.
    func removeRootFreshnessWitnessIfPresentLocked() throws {
        _ = try remove(name: Self.rootFreshnessWitnessFileName)
        try fsyncRootDirectory()
    }

    /// Called exactly once, from `init`, only when this exact instance's
    /// own `mkdirat` just won the race to create this directory. Safe to
    /// run without this directory's cross-process lock (unavailable from
    /// `init` regardless, since acquiring it is `async`) specifically
    /// because `mkdirat`'s own atomicity already proved this call is the
    /// directory's sole, exclusive creator: no other opener of this exact
    /// path could concurrently believe itself to also be the fresh
    /// creator, so nothing else could be racing to write this same file
    /// at the same time. A failure here is recovered durably, under this
    /// directory's real lock, the first time this instance runs
    /// ``ensureRootAuthorityInitializedLockedUnwrapped(isSurvivingEntryAcceptable:)``
    /// -- so this method intentionally never throws to its caller;
    /// `init` treats it as pure best-effort.
    func installRootFreshnessWitnessBestEffort() throws {
        try installRootFreshnessWitnessLocked()
    }

    /// Refuses to treat this directory as a genuinely pristine,
    /// never-before-used root unless the *only* entries it currently
    /// contains are the shared cross-process lock file
    /// (``SecureCacheDirectory/lockFileName``) — which, by every call
    /// site's own convention, always already exists by the time this
    /// runs, since ``acquireExclusiveLock()`` lazily creates it and every
    /// caller of ``ensureRootAuthorityInitializedLocked()`` has always
    /// already acquired that lock first — and, possibly, the root-
    /// freshness witness file itself (``rootFreshnessWitnessFileName``),
    /// which this exact instance's own `init` may have already durably
    /// written moments ago, before the freshness proof above was ever
    /// consulted.
    ///
    /// This check is now purely defense-in-depth: by the time it runs,
    /// this root's freshness has *already* been proven (see the caller),
    /// so this exists only to catch something unexpected -- a bug, or a
    /// foreign writer -- landing inside a provably fresh root before
    /// authority finished initializing, not to itself authorize treating
    /// the root as pristine.
    ///
    /// `isSurvivingEntryAcceptable` is consulted for every surviving
    /// entry other than those two fixed names — never for either of
    /// them, since both are this type's own, already-understood
    /// internal state — so a caller with domain knowledge of what its
    /// own entries look like (``AssetDiskCache``, the only production
    /// caller) can distinguish debris its own recovery pass already
    /// attempted (and may or may not have succeeded) to reclaim from
    /// genuine surviving cache content, without this generic type
    /// needing any awareness of that distinction itself.
    func rejectSurvivingEntriesForPristineRootLocked(
        isSurvivingEntryAcceptable: (String) throws -> Bool
    ) throws {
        let names = try listNames()
        func isReservedControlFileName(_ name: String) -> Bool {
            name == Self.lockFileName || name == Self.rootFreshnessWitnessFileName
        }
        for name in names where !isReservedControlFileName(name) {
            guard try isSurvivingEntryAcceptable(name) else {
                throw AssetError.clearFenceNotDurable(
                    "Cache root has surviving entries despite missing clear-epoch authority; " +
                        "refusing to treat it as a pristine root"
                )
            }
            // Descriptor-validate every survivor the caller's closure
            // vouches for by name: a symlink, directory, FIFO, or device
            // planted at a "recognized" name (most plausibly
            // ``AssetDiskCache/diskWritesDisabledMarkerName``, the only
            // name any production closure currently accepts here) is
            // never what that recognized name's own real writer would
            // ever produce, and must not be tolerated merely because its
            // *name* matches -- the freshness proof above already
            // authorizes epoch-zero initialization independently of this
            // loop, so this check exists purely to catch something
            // unexpected landing inside an otherwise-provably-fresh root,
            // not to itself decide whether initialization may proceed.
            guard let attributes = try attributes(name: name), attributes.isRegularFile else {
                throw AssetError.clearFenceNotDurable(
                    "Cache root has a non-regular-file survivor named '\(name)'; " +
                        "refusing to treat it as a pristine root"
                )
            }
        }
    }
}
