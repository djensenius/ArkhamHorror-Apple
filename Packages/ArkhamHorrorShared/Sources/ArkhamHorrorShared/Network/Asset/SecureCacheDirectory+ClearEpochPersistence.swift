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
}
