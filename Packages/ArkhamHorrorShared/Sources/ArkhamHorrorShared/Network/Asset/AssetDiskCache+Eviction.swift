import Foundation

/// Disk-quota eviction and accounted-byte usage for ``AssetDiskCache``,
/// split out of `AssetDiskCache+Recovery.swift` purely to keep that file
/// within this package's `file_length` convention; still part of the
/// same startup-recovery/quota subsystem documented there.
extension AssetDiskCache {
    /// One valid entry's identity, decoded metadata, and its metadata
    /// sidecar's exact serialized byte count (the same `Data` this decodes
    /// `metadata` from), so accounting never relies on an estimate for
    /// bytes that are actually persisted to disk.
    ///
    /// `payloadBytes` is likewise the actual on-disk payload file size (via
    /// a symlink-safe `fstatat`, never `metadata.encodedByteCount`): metadata
    /// is untrusted input, and if the payload file were ever larger than
    /// metadata claims — corruption, a partial write, or external
    /// modification — trusting the claimed size would let eviction
    /// undercount real disk usage until that exact key was next read via
    /// `get(_:)` and quarantined there. See ``get(_:)`` for the same
    /// actual-file-size check applied on the read path.
    struct Entry {
        let hash: String
        let metadata: AssetCacheMetadata
        let metadataBytes: Int
        let payloadBytes: Int
    }

    /// The exact bytes an entry counts against the disk quota: the real
    /// on-disk payload file size plus the real serialized size of its
    /// metadata sidecar file — never a fixed estimate, and never a value
    /// merely claimed by (untrusted) metadata.
    static func accountedBytes(for entry: Entry) -> Int {
        entry.payloadBytes + entry.metadataBytes
    }

    /// Evicts the least-recently-used entries (by
    /// ``AssetCacheMetadata/accessSequence``, tie-broken deterministically
    /// by the entry's own key hash — never filesystem `atime`, and never a
    /// wall-clock `Date`) until total accounted bytes falls to or below
    /// ``AssetCacheLimits/lowWaterMarkDiskBytes``. Quota accounting only
    /// ever subtracts an entry's bytes once *both* its payload and its
    /// metadata sidecar have been successfully removed: a failed removal
    /// leaves that entry's bytes fully counted (so quota accounting can
    /// never under-report real disk usage), and this method does not
    /// throw or stop early on an individual removal failure — it keeps
    /// evicting other entries so one unremovable entry can never mask
    /// eviction of everything else.
    ///
    /// Also sweeps orphaned `.bin`/`.tmp` files (see
    /// ``sweepOrphanFiles(names:referencedPayloadFilenames:)``) and every
    /// other cache-owned file this directory can contain — durable
    /// per-key tombstones, the whole-cache disabled markers, and the
    /// cross-process lock file itself — on every call, not merely once at
    /// startup, and folds whatever bytes any of those account for into
    /// `total` before comparing against the water marks: every one of
    /// those files physically occupies disk space this cache is
    /// responsible for, regardless of whether any currently valid
    /// metadata sidecar references it, and omitting any of them would let
    /// real usage exceed the budget this method is supposed to enforce
    /// without that ever being visible to it. Lists the directory exactly
    /// once for every purpose here, so a transient listing failure has
    /// one, not several, chances to affect a single `set` call.
    ///
    /// This is also this cache's sole "prove the budget" recovery path:
    /// if the directory cannot be listed, if it holds more entries than
    /// ``AssetCacheLimits/maxAccountableDirectoryEntryCount`` (an
    /// unaccountable flood, failed immediately rather than scanned), if
    /// the durable authority-record count is over
    /// ``AssetCacheLimits/maxAuthorityRecordCount`` and cannot be
    /// reclaimed back under it (see
    /// ``reconciledAuthorityRecordNames(_:)``), if any stray file's size
    /// cannot be determined, or if accounted usage still exceeds
    /// ``AssetCacheLimits/highWaterMarkDiskBytes`` even after evicting
    /// every evictable entry, this durably marks disk *writes* disabled
    /// (see ``AssetDiskCache/requireDiskWritesEnabledLocked()``) rather
    /// than merely returning early — a persistently-unknown or
    /// persistently-over-budget disk state must stop new bytes from
    /// being accepted at all, not merely fail to reclaim old ones. A
    /// fully successful pass (enumerable, fully accounted, and within
    /// budget by the end) clears that marker again, so a transient
    /// failure never permanently disables writes once conditions
    /// improve.
    @discardableResult
    func evictIfNeeded() -> AuthorityRecordQuotaState {
        guard let listedNames = try? directoryAccess.listNames() else {
            markDiskWritesDisabledLocked()
            return .withinLimit
        }
        guard listedNames.count <= limits.maxAccountableDirectoryEntryCount else {
            // A listing larger than anything this cache's own budgets
            // could produce cannot be reconciled, and attempting the
            // per-entry decode/stat pass below on it is exactly the
            // unbounded per-call cost this ceiling exists to prevent --
            // so fail closed *before* that pass, not after it.
            markDiskWritesDisabledLocked()
            return .withinLimit
        }
        guard let authorityReconciliation = reconciledAuthorityRecordNames(listedNames) else {
            // The authority-record count is over its own cap and cannot
            // be trusted; see ``reconciledAuthorityRecordNames(_:)``.
            markDiskWritesDisabledLocked()
            return .withinLimit
        }
        let names = authorityReconciliation.names
        guard var accounted = accountedUsage(names: names) else {
            // Every individual "physical usage is not fully known" case
            // is documented on ``accountedUsage(names:)`` itself; all of
            // them must fail closed exactly the same way an unenumerable
            // directory listing does.
            markDiskWritesDisabledLocked()
            return .withinLimit
        }
        if accounted.total > limits.highWaterMarkDiskBytes {
            accounted.entries.sort {
                $0.metadata.accessSequence != $1.metadata.accessSequence
                    ? $0.metadata.accessSequence < $1.metadata.accessSequence
                    : $0.hash < $1.hash
            }
            for entry in accounted.entries {
                guard accounted.total > limits.lowWaterMarkDiskBytes else { break }
                let payloadName = payloadFilename(
                    keyHash: entry.hash,
                    contentHash: entry.metadata.payloadSHA256Hex
                )
                let metadataName = "\(entry.hash).meta.json"
                let payloadRemoved = (try? directoryAccess.remove(name: payloadName)) ?? false
                let metadataRemoved = (try? directoryAccess.remove(name: metadataName)) ?? false
                guard payloadRemoved, metadataRemoved else { continue }
                accounted.total -= Self.accountedBytes(for: entry)
            }
        }
        let fsyncSucceeded = (try? directoryAccess.fsyncRootDirectory()) != nil
        guard fsyncSucceeded, accounted.total <= limits.highWaterMarkDiskBytes
        else {
            // Either this pass's own cleanup `fsync` could not be
            // confirmed durable, or accounted usage is still over budget
            // even after evicting every entry this pass could remove
            // (e.g. persistent removal failures) — both mean the budget
            // is not currently provably under control, so writes must
            // stay (or become) disabled until a future pass proves
            // otherwise.
            markDiskWritesDisabledLocked()
            return .withinLimit
        }
        clearDiskWritesDisabledLocked()
        return authorityReconciliation.state
    }

    /// Every currently-decodable entry plus the exact total accounted
    /// disk usage (entries + orphan/stray/quarantined-sidecar bytes),
    /// or `nil` if *any* component of that total could not be fully and
    /// safely determined -- factored out of ``evictIfNeeded()`` purely to
    /// keep that function's body within this package's
    /// `function_body_length` convention. Every `nil` case here means
    /// "physical usage is not fully known", which the caller must treat
    /// identically: fail closed exactly like an unenumerable directory
    /// listing, never silently under-counting or guessing.
    private func accountedUsage(
        names: [String]
    ) -> (entries: [Entry], total: Int)? {
        let (entriesResult, strandedSidecarBytes) = entries(names: names)
        let current = entriesResult
        // A quarantined invalid metadata sidecar's post-removal size
        // could not be confirmed.
        guard let strandedSidecarBytes else { return nil }
        let referencedPayloadFilenames = Set(current.map {
            payloadFilename(keyHash: $0.hash, contentHash: $0.metadata.payloadSHA256Hex)
        })
        // A surviving orphan candidate turned out to be a non-regular
        // entry whose real size cannot be safely determined.
        guard
            let strandedBytes = sweepOrphanFiles(
                names: names,
                referencedPayloadFilenames: referencedPayloadFilenames
            )
        else { return nil }
        // A stray cache-owned file's size could not be determined (e.g.
        // a tombstone/marker/lock file whose `fstatat` itself failed).
        guard let otherBytes = accountedStrayCacheFileBytes(names: names) else { return nil }
        let total = current.reduce(strandedBytes + otherBytes + strandedSidecarBytes) {
            $0 + Self.accountedBytes(for: $1)
        }
        return (current, total)
    }

    /// The accounted bytes of every cache-owned regular file in `names`
    /// that ``entries(names:)``/``sweepOrphanFiles(names:referencedPayloadFilenames:)``
    /// do not already account for — the whole-cache disabled-writes
    /// marker and the cross-process lock file — so ``evictIfNeeded()``'s
    /// budget accounting is never blind to any file this cache itself
    /// creates. Valid issuance-owner marker names are deliberately
    /// excluded: they are empty, randomly named advisory-lock control
    /// files whose count remains bounded by the authority-record cap and
    /// whose integrity is verified by every liveness probe. Returns `nil`
    /// (rather than silently under-counting) if any other file's actual
    /// on-disk size could not be determined, or if any of them turns out
    /// to be a **non-regular** entry.
    private func accountedStrayCacheFileBytes(names: [String]) -> Int? {
        var total = 0
        var sawUncertain = false
        for name in names {
            let isAlreadyAccountedElsewhere =
                name.hasSuffix(".meta.json") || name.hasSuffix(".tmp") || name.hasSuffix(".bin")
            let isZeroByteOwnerMarker = SecureCacheDirectory.isIssuanceOwnerMarkerName(name)
            guard !isAlreadyAccountedElsewhere, !isZeroByteOwnerMarker else { continue }
            guard let attributes = try? directoryAccess.attributes(name: name) else {
                sawUncertain = true
                continue
            }
            guard attributes.isRegularFile else {
                sawUncertain = true
                continue
            }
            total += attributes.size
        }
        return sawUncertain ? nil : total
    }
}
