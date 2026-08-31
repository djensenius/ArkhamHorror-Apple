import Foundation

/// The durable, cross-instance/cross-process per-key **issuance**
/// protocol for `AssetDiskCache` -- the disk-side half of the
/// compare-and-swap that lets two independent `AssetCacheService`/
/// `AssetDiskCache` instances (two OS processes, or two independently
/// constructed instances in one process, each pointed at this same
/// on-disk directory) agree on write ordering for the same key. A purely
/// actor-local (in-memory) applied-token dictionary cannot: each
/// instance keeps its own private state, so an older instance's delayed
/// write or removal has no way to learn a newer instance already
/// concluded for the exact same key.
///
/// **Why a cryptographically-random authority identifier, and why that
/// deletes an entire subsystem.** Issuance mints a fresh
/// ``AuthorityID`` -- 128 bits from `SecRandomCopyBytes` -- and durably
/// records it as this key's `issuedAuthorityID`. Every mutation is then
/// accepted only if the caller's own identifier is *exactly* that value.
/// There is no ordering comparison anywhere in this design, and
/// therefore nothing for a lost, reset, or rolled-back counter to
/// replay.
///
/// That single property is what let four separate defensive mechanisms
/// be deleted outright rather than patched further:
///
/// - a **mirror copy** of the per-key record, reconciled by revision,
///   which existed so that losing one copy could not be mistaken for a
///   pristine key;
/// - a per-key **issuance anchor** witness file, which existed to prove
///   the key's counter had never been reconstructed after loss;
/// - a root-level **key usage floor index**, which existed to make a
///   lost counter's replay range non-reusable;
/// - a directory-global **monotonic ticket sequence**, which existed so
///   a compacted-away key's future reissuance could not collide with its
///   own forgotten history.
///
/// Every one of those was an answer to "what if the value we are about
/// to hand out has been handed out before?" A freshly minted random
/// identifier cannot have been: not for this key, not for any other key,
/// not for any past epoch of this directory, and not for any sibling
/// process -- with probability `2^-128`, independent of what durable
/// state was lost first. So a **missing record at issuance time is now
/// unambiguously safe** to treat as "no operation has ever been issued
/// for this key," which is precisely the ambiguity every one of those
/// four mechanisms was built to resolve. A missing record at *mutation*
/// time is still a hard, typed failure -- see
/// ``acceptToken(_:currentEpoch:currentIssued:)`` -- because only
/// issuance may ever create a record.
///
/// The record lives entirely separate from the key's
/// ``AssetCacheMetadata`` sidecar: that sidecar is deleted the instant a
/// key's entry is definitively removed (a 404 invalidation, a failed
/// re-validation quarantine), and storing authority there would let "no
/// entry currently exists" collapse back to the same baseline a pristine
/// key reports. It is never deleted by an ordinary per-key
/// ``AssetDiskCache/remove(_:token:)`` -- only ``AssetDiskCache/removeAll()``
/// (always paired with a durable clear-epoch bump that independently and
/// unconditionally fences every previously issued token; see
/// `SecureCacheDirectory+ClearEpoch.swift`) ever removes it.
extension AssetDiskCache {
    /// The fixed leaf name of `key`'s single canonical durable authority
    /// record file. There is exactly one such file per key; nothing in
    /// this cache writes, reads, or reconstructs a second copy of it.
    func authorityRecordFilename(for key: AssetCacheKey) -> String {
        "\(key.digestHex).applied"
    }

    /// A single, atomic, cross-instance/cross-process issuance snapshot
    /// for `key`: the durable clear epoch, the freshly minted
    /// ``AuthorityID`` now durably recorded as this key's most recently
    /// issued authority, and the record revision that write landed at --
    /// all captured together under one exclusive-lock acquisition.
    ///
    /// Taken exactly once, as the very first step of issuing a fresh
    /// (never coalesced-into) fetch/revalidation/disk-hit operation --
    /// *before* the synchronous "check the coalescing dictionary, else
    /// create and issue" decision that follows it (see
    /// `AssetCacheService+Coalescing.swift`/
    /// `AssetCacheService+Revalidation.swift`) -- so the resulting
    /// ``AssetCacheService/CacheToken`` can be fully stamped,
    /// synchronously, at the moment it is actually issued, rather than
    /// restamped later from a value re-read after an unrelated
    /// suspension (the exact TOCTOU gap a prior review flagged:
    /// "durable epoch captured after operation issuance").
    struct IssuanceSnapshot: Sendable, Equatable {
        let clearEpoch: Int
        let authorityID: AuthorityID
        let revision: Int
    }

    /// Throws (fail closed) on any read/write failure -- callers treat a
    /// failed snapshot identically to an unstamped token: permanently
    /// non-authoritative, never a silent default.
    func beginIssuance(for key: AssetCacheKey) async throws -> IssuanceSnapshot {
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        let epoch = try secureDirectory.readPersistedClearEpoch()
        let issued = try issueAuthorityLocked(for: key)
        return IssuanceSnapshot(
            clearEpoch: epoch,
            authorityID: issued.authorityID,
            revision: issued.revision
        )
    }

    /// The revalidation counterpart to ``beginIssuance(for:)``, used
    /// whenever the operation being issued is re-validating an *already
    /// cached* entry (rather than starting a brand-new, no-prior-bytes
    /// fetch) -- the memory-hit/disk-hit branches of
    /// `AssetCacheService+Revalidation.swift`/`+DiskHit.swift`/
    /// `+RevalidationDiskFetch.swift`.
    ///
    /// Two genuinely different concerns are resolved atomically, under
    /// one lock hold, rather than conflated into one value:
    ///
    /// 1. **Provenance validation.** `expectedClearEpoch`/
    ///    `expectedAuthorityID` are the cached entry's own *historical*
    ///    publication stamp (``AssetCacheMetadata/clearEpochAtPublication``/
    ///    ``AssetCacheMetadata/authorityIDAtPublication``, threaded
    ///    through from ``AssetMemoryCache/CachedAsset/durableClearEpoch``/
    ///    ``AssetMemoryCache/CachedAsset/authorityID``) -- fixed at the
    ///    moment those exact bytes were last confirmed good. Compared,
    ///    under this same lock, against the *current* durable epoch and
    ///    this key's *currently applied* disposition. A mismatch on
    ///    either half means this exact cached entry is no longer the
    ///    durable state of record -- a cross-instance clear, or a
    ///    competing write for this same key, landed after these bytes
    ///    were last confirmed good -- and this returns `nil` rather than
    ///    any snapshot at all: the caller must treat that identically to
    ///    "no trustworthy cached entry" and fall through to a full,
    ///    uncached fetch.
    ///
    ///    Performed in the *same* lock acquisition, immediately before
    ///    minting a fresh identifier below, specifically so there is no
    ///    suspending round trip between "confirm this entry's provenance
    ///    still matches durable state" and "issue this operation's own
    ///    fresh authority" for a cross-instance clear or competing write
    ///    to land invisibly inside.
    ///
    /// 2. **Fresh per-operation authority.** Once provenance is
    ///    confirmed, this mints a genuinely fresh ``AuthorityID`` for
    ///    `key`, identical in kind to ``beginIssuance(for:)``'s own -- so
    ///    this operation's token is always uniquely its own, never
    ///    coincidentally equal to whatever is already applied. Reusing
    ///    the entry's historical identifier verbatim would silently break
    ///    ``removeIfApplied(_:token:)``'s exact-match
    ///    cancellation-retraction contract: it could no longer
    ///    distinguish "this exact cancelled operation's own applied
    ///    mutation" from "the entry's already-correct, untouched applied
    ///    state," and would retract a perfectly valid, unrelated entry
    ///    the instant an in-flight revalidation that never wrote anything
    ///    was cancelled.
    ///
    /// **Compares `key`'s full durable disposition, not merely its
    /// identifier.** ``commitRetractionLocked(for:token:destroy:)``
    /// durably commits `.retiring`/`.tombstone` under *exactly* the same
    /// identifier the content it is retracting was published under, so a
    /// stale cached entry whose historical stamp equals that unchanged
    /// identifier would otherwise still pass even though the content it
    /// pointed at has since been definitively torn down. Requiring
    /// ``KeyDispositionKind/content`` closes that window;
    /// `expectedContentHash`, when supplied, is compared too, as a
    /// further check against the exact bytes this stamp was captured
    /// alongside.
    ///
    /// Throws (fail closed, exactly like ``beginIssuance(for:)``) on any
    /// durable read/write failure; returns `nil` (a distinct,
    /// non-throwing "safe to fall through, nothing durably wrong
    /// happened" outcome) only for a genuine provenance mismatch.
    func beginRevalidationIssuance(
        for key: AssetCacheKey,
        expectedClearEpoch: Int,
        expectedAuthorityID: AuthorityID,
        expectedContentHash: String? = nil
    ) async throws -> IssuanceSnapshot? {
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        let epoch = try secureDirectory.readPersistedClearEpoch()
        let disposition = try currentDispositionLocked(for: key)
        guard
            epoch == expectedClearEpoch,
            disposition.kind == .content,
            disposition.authorityID == expectedAuthorityID,
            expectedContentHash == nil || disposition.contentHash == expectedContentHash
        else {
            return nil
        }
        let issued = try issueAuthorityLocked(for: key)
        return IssuanceSnapshot(
            clearEpoch: epoch,
            authorityID: issued.authorityID,
            revision: issued.revision
        )
    }
}
