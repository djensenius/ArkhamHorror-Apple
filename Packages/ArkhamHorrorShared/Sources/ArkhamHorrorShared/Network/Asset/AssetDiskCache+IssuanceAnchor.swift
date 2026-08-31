import Foundation

/// This review round's finding #1: a key's primary/mirror authority-
/// record pair, however faithfully reconciled against *each other* (see
/// `AssetDiskCache+DispositionReconciliation.swift`), can never by
/// itself detect a loss or rollback that strikes **both** copies
/// consistently -- both cleanly deleted at once, or both silently
/// replaced by some earlier, individually well-formed snapshot (a
/// restored backup, or any fault that manages to overwrite both copies
/// with the same stale content). Two copies written by the *same* code,
/// at the *same* time, are not independent witnesses against that
/// specific failure mode: whatever can make one wrong in that way can
/// just as easily make both wrong in the same way.
///
/// This file adds a **third, independently-named durable witness** —
/// this key's own issuance anchor, at ``AssetDiskCache/issuanceAnchorFilename(for:)``
/// — that is cross-checked against the primary/mirror pair's own
/// reconciled result on every read
/// (``AssetDiskCache/currentAuthorityRecordLocked(for:)``, via
/// ``enforceIssuanceAnchorLocked(_:for:)`` below) and is what actually
/// makes a consistent-but-wrong primary/mirror pair detectable: the
/// anchor is written *first*, as part of the exact same durable
/// transaction (``AssetDiskCache/commitAuthorityRecordLocked(_:for:)``)
/// that writes the mirror and then the primary, so it always durably
/// reflects the same value the primary/mirror pair is *supposed* to
/// reflect once that transaction fully lands.
///
/// **Bound to the durable clear epoch, not removed by any special-cased
/// code of its own.** An anchor's own `epoch` field records the durable
/// clear-epoch value in effect at the moment it was written; it is only
/// ever treated as binding when that value still matches the *current*
/// epoch. ``AssetDiskCache/removeAll()`` durably bumps the epoch
/// *before* physically sweeping every per-key file (including this
/// anchor -- it is not one of that method's own small, fixed set of
/// permanently-reserved names, exactly like the primary/mirror pair
/// themselves), so a real whole-cache clear needs no anchor-specific
/// logic at all: any anchor left over from before that clear is either
/// physically swept away shortly afterward, or, if physical cleanup
/// lags behind the epoch bump, simply no longer binding the instant it
/// is next read, since its own recorded epoch can no longer match.
///
/// **Fails closed unconditionally whenever the reconciled primary/mirror
/// result is behind this key's own binding anchor -- deliberately with
/// no repair path of its own.** Unlike a missing/torn *primary or
/// mirror* copy (each repairable from its own still-trustworthy
/// sibling), a reconciled result that is behind its own anchor has, by
/// definition, no trustworthy on-disk source left to repair *from* --
/// the anchor alone does not carry enough information to safely
/// reconstruct an entire lost disposition history, only enough to prove
/// one was lost. The one exception that requires no repair at all: a
/// reconciled result *ahead of* (or exactly matching) its own anchor is
/// always safe to accept outright, and opportunistically advances the
/// anchor to match -- the ordinary, expected outcome of every healthy,
/// uninterrupted commit.
extension AssetDiskCache {
    /// A single, atomic snapshot of `key`'s own durable issuance anchor:
    /// the clear epoch it was written under, alongside the full
    /// authority record it was witnessing at that moment. See this
    /// file's own type-level doc comment for why the *whole* record --
    /// not merely a bare ticket or revision number -- is what is
    /// anchored: an equal-revision cross-check
    /// (``enforceIssuanceAnchorLocked(_:for:)``) must be able to compare
    /// every field, not merely confirm two numbers match.
    struct KeyIssuanceAnchor: Codable, Sendable, Equatable {
        let epoch: Int
        let record: KeyAuthorityRecord
    }

    /// Generous enough for this anchor's own small, fixed-shape JSON
    /// encoding (an epoch integer wrapping one full
    /// ``KeyAuthorityRecord``) with ample headroom, while still bounding
    /// a read against a tampered or corrupt file of unbounded size.
    static let maxIssuanceAnchorBytes = 1024

    /// The fixed leaf name of `key`'s durable issuance anchor file --
    /// this file's own third, independently-named witness. Not
    /// reserved/excluded by ``AssetDiskCache/removeAll()``'s own sweep
    /// (see that method's doc comment for the full reserved-name list),
    /// so a real whole-cache clear physically removes it exactly like
    /// the primary/mirror pair -- and, in the meantime, its own recorded
    /// `epoch` field (see ``KeyIssuanceAnchor``) already stops it from
    /// binding the instant the durable clear-epoch counter that clear
    /// bumps no longer matches.
    func issuanceAnchorFilename(for key: AssetCacheKey) -> String {
        "\(key.digestHex).issuance-anchor"
    }

    /// The three mutually-exclusive states a single key's on-disk
    /// issuance anchor can be in -- mirrors
    /// `AssetDiskCache+DispositionReconciliation.swift`'s own
    /// `AuthorityRecordCopyState` for the identical reason: `.absent`
    /// and `.corrupt` must never be conflated, since only a cleanly
    /// absent (or no-longer-binding, stale-epoch) anchor may be silently
    /// (re)written, while a present-but-untrustworthy one is active
    /// evidence this key's whole authority cannot presently be trusted.
    private enum IssuanceAnchorCopyState {
        case absent
        case corrupt
        case valid(KeyIssuanceAnchor)
    }

    private func readIssuanceAnchorCopyStateLocked(
        name: String
    ) throws -> IssuanceAnchorCopyState {
        guard let data = try secureDirectory.read(
            name: name,
            maxBytes: Self.maxIssuanceAnchorBytes
        ) else {
            return .absent
        }
        guard let anchor = try? JSONDecoder.assetCache().decode(
            KeyIssuanceAnchor.self,
            from: data
        ), anchor.epoch >= 0, isValidAuthorityRecord(anchor.record) else {
            return .corrupt
        }
        return .valid(anchor)
    }

    /// The identical crash-consistency shape every other durable
    /// single-file write in this cache shares (bounded temp file,
    /// `fsync`, rename into place, `fsync` the containing directory).
    func writeIssuanceAnchorFileLocked(_ anchor: KeyIssuanceAnchor, name: String) throws {
        let data = try JSONEncoder.assetCache().encode(anchor)
        let tempName = name + ".tmp"
        try secureDirectory.writeTempAndFsync(tempName: tempName, data: data)
        try secureDirectory.renameAndFsyncDirectory(from: tempName, to: name)
    }

    /// Cross-checks `reconciled` -- the already-reconciled primary/mirror
    /// result ``currentAuthorityRecordLocked(for:)`` is about to return
    /// -- against `key`'s own durable issuance anchor, and returns both
    /// the value that is actually safe to trust and whether this key's
    /// anchor was *already*, independently, observed to be current-epoch
    /// before this call's own opportunistic re-anchoring may have run --
    /// the second half exists purely for
    /// ``AssetDiskCache/enforceKeyUsageFloorLocked(_:for:)``'s own use
    /// (see that method's own doc comment): it needs to distinguish "this
    /// key has a real, current-epoch commit on record" from "this key's
    /// anchor is merely being freshly (re)written by this very call, for
    /// a key that has never actually been active in the current epoch at
    /// all" -- a distinction this call's own opportunistic writes below
    /// would otherwise erase by the time any later caller re-reads the
    /// anchor file itself. See this file's own type-level doc comment for
    /// the full reasoning; in summary:
    ///
    /// - **Anchor corrupt** (present, but unparsable or structurally
    ///   invalid): fails closed unconditionally, exactly like a corrupt
    ///   primary/mirror copy -- an untrustworthy anchor is itself active
    ///   evidence, never silently ignored.
    /// - **Anchor absent**: not binding. If `reconciled` is non-pristine
    ///   (this key's very first commit, or a crash gap in
    ///   ``AssetDiskCache/commitAuthorityRecordLocked(_:for:)``'s own
    ///   three-file write sequence -- both cases where `reconciled` is
    ///   already known to genuinely describe the *current* epoch), this
    ///   opportunistically (best-effort) writes a fresh, current-epoch
    ///   anchor to match it, so a *future* read has one to cross-check
    ///   against; a genuinely pristine key needs no anchor at all yet.
    ///   Returns `reconciled` unchanged either way, with
    ///   `wasCurrentEpoch: false`.
    /// - **Anchor present but stamped with a stale (no longer current)
    ///   epoch**: not binding, and -- unlike the absent case just above --
    ///   never opportunistically re-anchored here. `reconciled` here
    ///   still describes the *pre-clear* world (see this method's own
    ///   body for why durably re-stamping it as current-epoch would
    ///   manufacture false evidence for the very next reader). Returns
    ///   `reconciled` unchanged, with `wasCurrentEpoch: false`; only a
    ///   fresh ``AssetDiskCache/issueTicketLocked(for:)`` commit may ever
    ///   durably re-anchor this key at the current epoch.
    /// - **Anchor valid and current-epoch, `reconciled.revision` ahead
    ///   of the anchor's own recorded revision**: the ordinary, healthy
    ///   outcome of every uninterrupted commit (the anchor is always
    ///   written first -- see ``AssetDiskCache/commitAuthorityRecordLocked(_:for:)``).
    ///   Opportunistically advances the anchor to match, returns
    ///   `reconciled`.
    /// - **Anchor valid and current-epoch, revisions exactly equal**:
    ///   the two must agree on every field (they were, by construction,
    ///   the exact same commit) -- returns `reconciled` if so, fails
    ///   closed if not (a same-revision disagreement can never
    ///   legitimately arise).
    /// - **Anchor valid and current-epoch, `reconciled.revision` *behind*
    ///   the anchor's own recorded revision**: `reconciled` is stale --
    ///   whether from a consistent rollback of both the primary and
    ///   mirror copies, or from a crash landing after this key's anchor
    ///   was durably advanced but strictly before the mirror/primary
    ///   pair caught up (the one crash window
    ///   ``AssetDiskCache/commitAuthorityRecordLocked(_:for:)``'s
    ///   anchor-first ordering can still leave behind). **Fails closed
    ///   unconditionally, with no repair attempted** -- see this file's
    ///   own type-level doc comment for why a repair is not safe here,
    ///   unlike every other repair this cache performs.
    func enforceIssuanceAnchorLocked(
        _ reconciled: KeyAuthorityRecord,
        for key: AssetCacheKey
    ) throws -> (record: KeyAuthorityRecord, wasCurrentEpoch: Bool) {
        let anchorName = issuanceAnchorFilename(for: key)
        let anchorState = try readIssuanceAnchorCopyStateLocked(name: anchorName)
        let currentEpoch = try secureDirectory.readPersistedClearEpoch()
        guard case let .valid(anchor) = anchorState else {
            if case .corrupt = anchorState {
                throw AssetError.cachePersistenceFailed(
                    "Issuance anchor for this key is present but cannot be trusted; refusing" +
                        " to trust the reconciled authority record without it."
                )
            }
            if reconciled != .pristine {
                _ = try? writeIssuanceAnchorFileLocked(
                    KeyIssuanceAnchor(epoch: currentEpoch, record: reconciled),
                    name: anchorName
                )
                opportunisticallySyncFloorLocked(reconciled, for: key, currentEpoch: currentEpoch)
            }
            return (reconciled, false)
        }
        guard anchor.epoch == currentEpoch else {
            // A stale leftover from before a legitimate whole-cache
            // clear -- not binding, and *never* opportunistically
            // re-anchored at the current epoch here (unlike the
            // anchor-absent branch just above, which is safe to
            // opportunistically write precisely because that branch
            // only fires when `reconciled` is itself already known to
            // be current-epoch-legitimate data -- this key's very first
            // commit, or a crash gap in `commitAuthorityRecordLocked(_:for:)`'s
            // own three-file write sequence). `reconciled` here is, by
            // construction, still describing the *pre-clear* world (its
            // own primary/mirror pair, and this now-stale anchor, were
            // never touched by the clear that bumped `currentEpoch` --
            // see ``AssetDiskCache/removeAll()``'s own doc comment for
            // why every per-key file is swept best-effort, never
            // specially reserved, so a partially-failed sweep can leave
            // any of them fully intact). Durably re-stamping *this exact,
            // still-stale* ticket/disposition pair as `epoch:
            // currentEpoch` here would manufacture false evidence: the
            // very next reader (this call's own eventual caller
            // included, on a subsequent read before anything has
            // actually been freshly re-issued/republished) would then
            // see `wasCurrentEpoch: true` and wrongly treat this
            // leftover's own stale ticket as a binding floor and its
            // stale disposition as live, current-epoch content --
            // exactly the resurrection this whole mechanism exists to
            // prevent. Only ``AssetDiskCache/issueTicketLocked(for:)``'s
            // own fresh commit (via ``commitAuthorityRecordLocked(_:for:)``,
            // once a *new* ticket has actually been reserved and this
            // key's own disposition reset to ``KeyDisposition/pristine``)
            // may ever durably re-anchor this key at the current epoch.
            return (reconciled, false)
        }
        if reconciled.revision > anchor.record.revision {
            _ = try? writeIssuanceAnchorFileLocked(
                KeyIssuanceAnchor(epoch: currentEpoch, record: reconciled),
                name: anchorName
            )
            return (reconciled, true)
        }
        guard reconciled.revision == anchor.record.revision else {
            throw AssetError.cachePersistenceFailed(
                "Reconciled authority record is behind this key's own durable issuance" +
                    " anchor -- a prior ticket/disposition may have been lost or rolled back;" +
                    " refusing to resume from an unproven state."
            )
        }
        guard reconciled == anchor.record else {
            throw AssetError.cachePersistenceFailed(
                "Reconciled authority record disagrees with its own durable issuance anchor" +
                    " at the same revision, which can never legitimately arise."
            )
        }
        return (reconciled, true)
    }

    /// Best-effort mirrors this method's own opportunistic anchor
    /// (re)writes, above, into this cache's root-level key usage floor
    /// index as well -- so a key this call has just (re)anchored at the
    /// current epoch is never left with an anchor claiming current-epoch
    /// standing while the floor index still has no entry for it at all.
    ///
    /// Without this, a *second*, later read of the exact same key (for
    /// example ``currentKeyAuthority(for:)`` called after an earlier
    /// ``currentKeyDisposition(for:)`` already ran this exact
    /// opportunistic repair) would observe `wasCurrentEpoch: true` from
    /// the now-freshly-written anchor, while
    /// ``enforceKeyUsageFloorLocked(_:for:anchorWasCurrentEpoch:)``'s own
    /// missing-entry branch requires exactly that flag to be `false` to
    /// tolerate an absent floor entry -- permanently, spuriously
    /// fail-closing a key this call itself just finished vouching for.
    /// Failure here is silently tolerated exactly like every other
    /// opportunistic repair in this file: it only ever improves a
    /// *future* read's resilience, never a precondition for trusting the
    /// value this call has already determined is safe.
    private func opportunisticallySyncFloorLocked(
        _ reconciled: KeyAuthorityRecord,
        for key: AssetCacheKey,
        currentEpoch: Int
    ) {
        _ = try? commitKeyUsageFloorLocked(
            for: key,
            issuedTicket: reconciled.issuedTicket,
            epoch: currentEpoch
        )
    }
}
