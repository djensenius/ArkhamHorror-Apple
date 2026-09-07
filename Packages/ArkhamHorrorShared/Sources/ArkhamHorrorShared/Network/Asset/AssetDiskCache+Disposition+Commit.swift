import Foundation

/// Split out of `AssetDiskCache+Disposition.swift` purely to stay under
/// this package's file-length lint limit. Contains the commit/mutation
/// side of the per-key authority-record protocol that file's own
/// type-level doc comment introduces: durably committing a full
/// ``AssetDiskCache/KeyAuthorityRecord`` (one file, one atomic write),
/// resolving a single mutation's authority identifier, and the two
/// commit entry points every publish/touch/retraction actually calls.
extension AssetDiskCache {
    /// The disposition half of ``currentAuthorityRecordLocked(for:)`` --
    /// kept as its own entry point since most callers only ever need
    /// this half.
    func currentDispositionLocked(for key: AssetCacheKey) throws -> KeyDisposition {
        try currentAuthorityRecordLocked(for: key).disposition
    }

    /// Durably commits `record` as `key`'s new authority record, to the
    /// one canonical file this design has (see
    /// `AssetDiskCache+Disposition.swift`'s type-level doc comment for
    /// why there are no longer any mirror/anchor/floor copies), via
    /// ``writeAuthorityRecordFileLocked(_:name:)``'s atomic temp +
    /// `fsync` + rename + directory-`fsync` shape. Must only ever be
    /// called while the caller already holds this instance's
    /// ``SecureCacheDirectory/acquireExclusiveLock()``.
    ///
    /// **Re-reads this key's current record and validates the proposed
    /// transition against it before writing anything.** Two independent
    /// guards, both required to hold:
    ///
    /// 1. `record.transitionRevision` must be *exactly* one past the
    ///    currently durable revision, via ``checkedAdvancedRevision(_:)``.
    /// 2. The proposed disposition must be a legal successor of the
    ///    currently applied one, per
    ///    ``isLegalDispositionTransition(from:to:)``.
    ///
    /// **What guard 1 actually proves -- and what it does not.** The
    /// caller already holds this directory's cross-process exclusive
    /// lock for the whole mutation, and read the same record under that
    /// same hold, so nothing else can have written this file in between:
    /// this re-read observes exactly what the caller's own earlier read
    /// saw. That makes the check a *defensive consistency assertion
    /// against a same-call-site logic error* -- a caller that computed
    /// the wrong next revision, or (if the lock were somehow not
    /// genuinely exclusive, which would be a locking bug elsewhere) a
    /// legitimate competing commit for this same key -- and nothing
    /// more. It emphatically does **not** detect a rollback performed by
    /// an external actor at an arbitrary point in time: such an actor
    /// restores a self-consistent older record, which this check reads
    /// as simply "the current state", and that whole class of tampering
    /// is out of scope for this design anyway (see
    /// `AssetDiskCache+Disposition.swift`'s "Threat model" section). The
    /// check is kept because it is cheap (one bounded small-file read)
    /// and catches real programming mistakes at the single choke point
    /// every commit funnels through -- not because it proves anything
    /// about tamper resistance.
    ///
    /// Both guards fail closed with a typed
    /// ``AssetError/cachePersistenceFailed(_:)``.
    func commitAuthorityRecordLocked(
        _ record: KeyAuthorityRecord,
        for key: AssetCacheKey
    ) throws {
        let current = try currentAuthorityRecordLocked(for: key)
        guard try record.transitionRevision == checkedAdvancedRevision(current.transitionRevision)
        else {
            throw AssetError.cachePersistenceFailed(
                "Refusing to commit an authority record whose transition revision does not" +
                    " advance this key's own durable revision by exactly one."
            )
        }
        guard isLegalDispositionTransition(
            from: current.disposition,
            to: record.disposition
        ) else {
            throw AssetError.cachePersistenceFailed(
                "Refusing to commit a disposition that regresses this key's own durable" +
                    " state machine for an already-committed authority identifier."
            )
        }
        try writeAuthorityRecordFileLocked(record, name: authorityRecordFilename(for: key))
    }

    /// The per-authority disposition state machine, enforced at the one
    /// durable commit choke point.
    ///
    /// A transition to a *different* ``AuthorityID`` is always legal: it
    /// is by definition a different operation's commit, and whether that
    /// operation is entitled to mutate this key at all is decided
    /// entirely by ``acceptToken(_:currentEpoch:currentIssued:)``'s own
    /// exact-equality compare-and-swap against
    /// ``KeyAuthorityRecord/issuedAuthorityID``, not here.
    ///
    /// For the *same* identifier, only the forward edges this cache's own
    /// commit paths can actually produce are legal: an unchanged
    /// disposition (what a fresh issuance re-commits verbatim), a
    /// content-preserving re-publish at the identical payload hash (what
    /// ``touch(_:metadata:token:)`` commits for a 304), `content ->
    /// retiring`, and `retiring -> tombstone`. Everything else --
    /// re-pointing an already-committed identifier at different bytes,
    /// resurrecting a `.retiring`/`.tombstone` back into `.content`, or
    /// walking the two-phase retraction backward -- can never arise
    /// legitimately and is rejected rather than durably recorded.
    private func isLegalDispositionTransition(
        from current: KeyDisposition,
        to next: KeyDisposition
    ) -> Bool {
        guard current != next else { return true }
        guard current.authorityID == next.authorityID else { return true }
        switch (current.kind, next.kind) {
        case (.content, .content):
            return current.contentHash == next.contentHash
        case (.content, .retiring), (.retiring, .tombstone):
            return true
        default:
            return false
        }
    }

    /// Durably commits `disposition` as `key`'s new applied disposition,
    /// preserving this key's own currently-recorded `issuedAuthorityID`
    /// (nothing newer can have been issued since, by construction: every
    /// token-gated mutation only reaches this point after
    /// ``acceptToken(_:currentEpoch:currentIssued:)`` proved the caller's
    /// own identifier *is* the currently-issued one, under the same
    /// still-held lock) and advancing `transitionRevision` by exactly
    /// one. The whole record is re-read first and rewritten as one
    /// atomic unit, so there is no window in which only part of this
    /// key's authority is durably updated.
    func commitDispositionLocked(
        _ disposition: KeyDisposition,
        for key: AssetCacheKey,
        settlingIssuance: Bool = false
    ) throws {
        let current = try currentAuthorityRecordLocked(for: key)
        try commitAuthorityRecordLocked(
            KeyAuthorityRecord(
                issuedAuthorityID: current.issuedAuthorityID,
                disposition: disposition,
                transitionRevision: checkedAdvancedRevision(current.transitionRevision),
                openIssuanceOwnerID: settlingIssuance ? nil : current.openIssuanceOwnerID
            ),
            for: key
        )
    }

    /// The exact ``AuthorityID`` a token-gated caller's own already-issued
    /// authority resolves to, or a freshly minted one for an
    /// unconditional (`token: nil`) caller -- shared dispatch logic every
    /// commit path below uses identically. A token-gated commit must
    /// always reuse its own already-accepted identifier verbatim, never
    /// mint a fresh one (which would durably supersede a different,
    /// already-issued-but-not-yet-applied operation for this same key);
    /// an unconditional caller has no identifier of its own to reuse and
    /// must mint a brand-new one so a *later* replay of a token issued
    /// *before* this call can never again satisfy
    /// ``acceptToken(_:currentEpoch:currentIssued:)``.
    func resolvedMutationAuthorityLocked(
        for key: AssetCacheKey,
        token: AssetCacheService.CacheToken?
    ) throws -> AuthorityID {
        if let authorityID = token?.diskAuthorityID {
            return authorityID
        }
        return try issueAuthorityLocked(for: key, trackingOpenIssuance: false).authorityID
    }

    /// Durably commits a `.content` disposition for `key` -- the
    /// counterpart, for a successful publish/touch, to
    /// ``commitRetractionLocked(for:token:destroy:)``'s two-phase
    /// removal. Both ``set(_:payload:metadata:token:)`` and
    /// ``touch(_:metadata:token:)`` resolve `authorityID` themselves (via
    /// ``resolvedMutationAuthorityLocked(for:token:)``, exactly once)
    /// before ever calling this, and stamp that identical value into the
    /// metadata sidecar they each just wrote, so this key's disposition
    /// and its metadata's own ``AssetCacheMetadata/authorityIDAtPublication``
    /// can never disagree.
    @discardableResult
    func commitPublicationLocked(
        for key: AssetCacheKey,
        authorityID: AuthorityID,
        contentHash: String
    ) throws -> AuthorityID {
        try commitDispositionLocked(
            KeyDisposition(authorityID: authorityID, kind: .content, contentHash: contentHash),
            for: key,
            settlingIssuance: true
        )
        retireLocallyOpenIssuanceLocked(authorityID)
        return authorityID
    }

    /// Durably commits a key's removal via the two-phase, crash-safe
    /// transition `AssetDiskCache+Disposition.swift`'s type-level doc
    /// comment describes: `.retiring` *before* `destroy` ever runs,
    /// `.tombstone` only once `destroy` has returned without throwing.
    /// Used by ``AssetDiskCache/remove(_:token:)`` (a definitive 404) as
    /// one single locked transaction -- unlike
    /// ``AssetDiskCache/beginRetraction(_:token:)``/
    /// ``AssetDiskCache/completeRetraction(_:token:)``, which durably
    /// commit that same pair as two *separately lockable, separately
    /// awaitable* steps instead.
    ///
    /// Every durable state-write here always throws straight out on
    /// failure -- a caller that cannot durably confirm reaching
    /// `.tombstone` must never treat this as having succeeded: the
    /// disposition durably stays at `.retiring`, which is exactly as
    /// unreadable to ``AssetDiskCache/get(_:)`` as a confirmed tombstone,
    /// and which self-heals the instant a future mutation for this exact
    /// key commits its own newer disposition over it.
    @discardableResult
    func commitRetractionLocked(
        for key: AssetCacheKey,
        token: AssetCacheService.CacheToken?,
        destroy: () throws -> Void
    ) throws -> AuthorityID {
        let authorityID = try resolvedMutationAuthorityLocked(for: key, token: token)
        try commitDispositionLocked(
            KeyDisposition(authorityID: authorityID, kind: .retiring, contentHash: nil),
            for: key,
            settlingIssuance: true
        )
        retireLocallyOpenIssuanceLocked(authorityID)
        try destroy()
        try commitDispositionLocked(
            KeyDisposition(authorityID: authorityID, kind: .tombstone, contentHash: nil),
            for: key
        )
        return authorityID
    }

    /// Returns this cache's lazily-created session owner. Called only
    /// while holding the root lock, so a concurrent orphan sweep cannot
    /// observe the new marker before it is locked.
    func currentIssuanceOwnerLocked() throws -> CacheIssuanceOwner {
        if let issuanceOwner {
            return issuanceOwner
        }
        let owner = try secureDirectory.makeIssuanceOwner()
        issuanceOwner = owner
        return owner
    }

    /// Retires one authority local to this cache. Once no local
    /// operations remain, removes its session marker while still holding
    /// the root lock; a failed removal merely leaves harmless crash
    /// residue for startup recovery.
    func retireLocallyOpenIssuanceLocked(_ authorityID: AuthorityID) {
        locallyOpenIssuanceAuthorityIDs.remove(authorityID)
        releaseIssuanceOwnerIfUnusedLocked()
    }

    /// Releases the shared session owner only when no local authority can
    /// still lawfully publish under it.
    func releaseIssuanceOwnerIfUnusedLocked() {
        guard locallyOpenIssuanceAuthorityIDs.isEmpty, let owner = issuanceOwner else { return }
        _ = try? secureDirectory.remove(name: owner.markerName)
        issuanceOwner = nil
    }

    /// Retires an operation before its terminal settlement acquires the
    /// root lock. Returning the released owner lets that later locked
    /// phase unlink its stale marker if no sibling operation still needs
    /// the same session.
    func retireLocallyOpenIssuanceBeforeLock(_ authorityID: AuthorityID) -> AuthorityID? {
        locallyOpenIssuanceAuthorityIDs.remove(authorityID)
        guard locallyOpenIssuanceAuthorityIDs.isEmpty, let owner = issuanceOwner else {
            return nil
        }
        issuanceOwner = nil
        return owner.identifier
    }

    /// Test/diagnostic-only: a single, lock-acquiring read of `key`'s
    /// current durable disposition. Not used by any production code path,
    /// but exposed so tests can assert on this exact durable state
    /// directly.
    func currentKeyDisposition(for key: AssetCacheKey) async throws -> KeyDisposition {
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        return try currentDispositionLocked(for: key)
    }

    /// Test/diagnostic-only: the whole of `key`'s current durable
    /// authority record -- issued identifier, applied disposition, and
    /// transition revision -- read together under one lock hold. Exists
    /// so tests can assert on the transition revision (which no
    /// production caller ever needs separately from the commit path that
    /// advances it) without reaching around the lock.
    func currentKeyRecord(for key: AssetCacheKey) async throws -> KeyAuthorityRecord {
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        return try currentAuthorityRecordLocked(for: key)
    }
}
