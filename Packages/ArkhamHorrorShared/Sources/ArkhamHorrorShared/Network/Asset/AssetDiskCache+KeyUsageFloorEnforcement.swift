import Foundation

/// The cross-check half of `AssetDiskCache+KeyUsageFloor.swift`'s own
/// root-level key usage floor index -- split into its own file purely
/// to keep that file within this package's length convention. See that
/// file's own type-level doc comment for the full reasoning this index
/// closes.
extension AssetDiskCache {
    /// Cross-checks `reconciled` -- the already-reconciled, already
    /// anchor-checked authority record ``currentAuthorityRecordLocked(for:)``
    /// is about to return -- against this key's own entry (if any) in the
    /// durable, root-level floor index, and returns the value that is
    /// actually safe to trust. See this file's own type-level doc comment
    /// for the full reasoning this closes; in summary:
    ///
    /// - **Index corrupt**: fails closed unconditionally, exactly like a
    ///   corrupt primary/mirror/anchor copy.
    /// - **Index absent, or present but stamped with a stale epoch**:
    ///   never legitimately arises once a root has been through
    ///   ``bootstrapKeyUsageFloorIndexIfGenuinelyFreshLocked(epoch:)``/
    ///   ``resetKeyUsageFloorIndexLocked(epoch:)`` for a key that has
    ///   ever actually had a durable, current-epoch commit land --
    ///   `anchorWasCurrentEpoch` (see `enforceIssuanceAnchorLocked(_:for:)`'s
    ///   own doc comment) is exactly how this call distinguishes that
    ///   dangerous case from the merely-inert one: a key whose own
    ///   anchor was *not itself already, independently* current-epoch
    ///   has, by construction, never had a real commit land since the
    ///   floor index was last reset either -- most commonly because a
    ///   whole-cache clear durably bumped the epoch and reset this index
    ///   to empty, but then failed at its own subsequent directory
    ///   listing before the physical per-key sweep ever ran (see
    ///   ``AssetDiskCache/removeAll()``), leaving every one of this
    ///   key's own per-key files fully intact yet still stamped with the
    ///   prior epoch. That scenario is already, identically tolerated by
    ///   the issuance anchor's own stale-epoch handling, and this index
    ///   must agree with it rather than regress it: `reconciled` is
    ///   trusted unchanged whenever `!anchorWasCurrentEpoch`, exactly
    ///   like the anchor itself. Only when the anchor already,
    ///   independently proved a real current-epoch commit landed
    ///   (`anchorWasCurrentEpoch == true`) -- which this index's own
    ///   floor-first commit ordering guarantees would also have written
    ///   this exact floor entry at that same moment -- does an absent
    ///   index or a missing/stale entry become genuinely inexplicable,
    ///   and `reconciled` may then only be
    ///   ``KeyAuthorityRecord/pristine``.
    /// - **No entry recorded for this key**: this key has never had a
    ///   ticket issued for it (per this index's own bootstrap/commit
    ///   invariant, an issuance always records its own floor entry
    ///   *before* anything else -- see
    ///   ``commitKeyUsageFloorLocked(for:issuedTicket:epoch:)``) -- or its
    ///   entry was safely compacted away after being durably confirmed
    ///   ``KeyDispositionKind/tombstone`` (see
    ///   ``compactKeyUsageFloorIfNeededLocked(names:)``), in which case
    ///   this key's own per-key files must also have been deleted in that
    ///   exact same compaction pass, so `reconciled` can only ever again
    ///   be pristine here too -- OR (exactly as above) `!anchorWasCurrentEpoch`,
    ///   the failed-clear-listing scenario. Either that or pristine;
    ///   anything else fails closed.
    /// - **Entry recorded, `reconciled.issuedTicket` at or ahead of it**:
    ///   the ordinary, healthy outcome of every uninterrupted commit.
    ///   Returns `reconciled` unchanged.
    /// - **Entry recorded, `reconciled.issuedTicket` *behind* it**: this
    ///   round's finding #1, closed -- whether from a consistent loss or
    ///   rollback of all three of this key's own per-key files, or from a
    ///   crash landing after this floor entry was durably advanced but
    ///   before the rest of ``commitAuthorityRecordLocked(_:for:)``'s own
    ///   writes caught up. **Fails closed unconditionally, with no repair
    ///   attempted**, exactly like the identical crash window the
    ///   issuance anchor itself already accepts as permanently
    ///   fail-closed for that one key until an explicit
    ///   ``AssetDiskCache/removeAll()``.
    func enforceKeyUsageFloorLocked(
        _ reconciled: KeyAuthorityRecord,
        for key: AssetCacheKey,
        anchorWasCurrentEpoch: Bool
    ) throws -> KeyAuthorityRecord {
        let currentEpoch = try secureDirectory.readPersistedClearEpoch()
        switch try readKeyUsageFloorIndexStateLocked() {
        case .corrupt:
            throw AssetError.cachePersistenceFailed(
                "Key usage floor index is present but cannot be trusted; refusing to trust" +
                    " the reconciled authority record without it."
            )
        case .absent:
            guard reconciled == .pristine || !anchorWasCurrentEpoch else {
                throw AssetError.cachePersistenceFailed(
                    "This cache root has no key usage floor index at all, but this key's own" +
                        " authority record already proved a current-epoch commit landed;" +
                        " refusing to trust unproven state."
                )
            }
            return reconciled
        case let .valid(index):
            guard index.epoch == currentEpoch else {
                guard reconciled == .pristine || !anchorWasCurrentEpoch else {
                    throw AssetError.cachePersistenceFailed(
                        "Key usage floor index is stamped with a stale clear epoch, but this" +
                            " key's own authority record already proved a current-epoch" +
                            " commit landed; refusing to trust unproven state."
                    )
                }
                return reconciled
            }
            guard let entry = index.entries[key.digestHex] else {
                guard reconciled == .pristine || !anchorWasCurrentEpoch else {
                    throw AssetError.cachePersistenceFailed(
                        "This key has no entry in this cache's own root-level key usage floor" +
                            " index, but its authority record already proved a current-epoch" +
                            " commit landed; refusing to trust state this cache's own root" +
                            " witness never recorded."
                    )
                }
                return reconciled
            }
            guard reconciled.issuedTicket >= entry.issuedTicket else {
                throw AssetError.cachePersistenceFailed(
                    "This key's reconciled authority record is behind this cache's own" +
                        " root-level key usage floor index -- a prior ticket may have been" +
                        " lost or rolled back across every one of this key's own files at" +
                        " once; refusing to resume from an unproven state."
                )
            }
            return reconciled
        }
    }
}
