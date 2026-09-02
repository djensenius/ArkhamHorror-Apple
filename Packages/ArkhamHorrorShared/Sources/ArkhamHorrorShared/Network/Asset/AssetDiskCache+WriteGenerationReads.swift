import Foundation

/// The read/issuance primitives for `key`'s durable authority record --
/// split out of `AssetDiskCache+WriteGeneration.swift` purely to keep
/// that file within this package's `file_length` convention. Every member
/// here must only ever be called while the caller already holds this
/// instance's own ``SecureCacheDirectory/acquireExclusiveLock()``.
extension AssetDiskCache {
    /// Reads `key`'s current durable authority record from its one
    /// canonical file.
    ///
    /// A clean "does not exist" miss is ``KeyAuthorityRecord/pristine``.
    /// Unlike the predecessor counter-based design, that is no longer an
    /// ambiguous answer that some second witness must disambiguate: an
    /// absent record means the next issuance mints a brand-new random
    /// ``AuthorityID``, which cannot match anything any still-in-flight
    /// operation holds, so it does not matter whether the file is
    /// genuinely pristine or was independently lost after real prior use
    /// (see `AssetDiskCache+WriteGeneration.swift`'s type-level doc
    /// comment). What a missing record *may* never do is authorize a
    /// mutation: ``acceptToken(_:currentEpoch:currentIssued:)`` compares
    /// a caller's identifier for exact equality against
    /// ``KeyAuthorityRecord/issuedAuthorityID``, and the pristine
    /// sentinel identifier can never equal a real one.
    ///
    /// Any *other* failure -- a symlink or non-regular entry at this
    /// name, an oversized file, unparsable JSON, or a structurally
    /// impossible record per ``isValidAuthorityRecord(_:)`` -- is a hard,
    /// typed, fail-closed failure, never silently degraded to the
    /// pristine baseline and never "repaired" from anywhere, because
    /// this design has no second copy to repair it from.
    func currentAuthorityRecordLocked(for key: AssetCacheKey) throws -> KeyAuthorityRecord {
        // `SecureCacheDirectory.read(name:maxBytes:)` already
        // distinguishes a clean "does not exist" miss (`nil`) from every
        // other failure mode (wrong type, oversized, short/interrupted
        // read) by *throwing* for the latter -- deliberately propagated
        // here, unswallowed.
        guard let data = try secureDirectory.read(
            name: authorityRecordFilename(for: key),
            maxBytes: Self.maxDispositionBytes
        ) else {
            return .pristine
        }
        guard
            let record = try? JSONDecoder.assetCache().decode(
                KeyAuthorityRecord.self,
                from: data
            ),
            isValidAuthorityRecord(record)
        else {
            throw AssetError.cachePersistenceFailed(
                "Authority record for this key is present but cannot be trusted; there is no" +
                    " second copy to fall back to, and one is never reconstructed."
            )
        }
        return record
    }

    /// Reads `key`'s current durable most-recently-issued
    /// ``AuthorityID`` -- the single value every mutation
    /// compare-and-swap compares against.
    func currentIssuedAuthorityLocked(for key: AssetCacheKey) throws -> AuthorityID {
        try currentAuthorityRecordLocked(for: key).issuedAuthorityID
    }

    /// A single, atomic, cross-instance/cross-process authority snapshot
    /// for `key` -- the durable clear epoch and this key's own most
    /// recently *issued* ``AuthorityID``, read together under one
    /// exclusive-lock acquisition. Used by
    /// ``AssetCacheService/memoryEntryStillCurrent(_:storedAuthorityID:for:)``
    /// to decide whether an already-cached memory entry is still safe to
    /// serve without re-validating.
    ///
    /// **Deliberately reads the most recently *issued* identifier, never
    /// merely the currently *applied* one, and reads both fields
    /// together under one lock hold rather than as two separately-locked
    /// calls.** Two separately-locked reads are a torn read: a sibling
    /// instance's whole-cache clear landing between them leaves this call
    /// observing a pre-clear epoch paired with a post-clear identifier,
    /// neither half describing the same durable moment. And comparing
    /// only against the applied disposition has an independent defect: a
    /// sibling service can *issue* a fresh authority for this exact key
    /// the moment it begins a fetch, strictly before that operation's own
    /// mutation lands -- during that whole window an applied-only
    /// comparison would keep reporting an older memory entry "still
    /// current" even though a strictly newer, already-in-flight operation
    /// may complete with entirely different content (or a definitive
    /// removal) at any moment.
    func currentKeyAuthority(for key: AssetCacheKey) async throws -> KeyAuthoritySnapshot {
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        let epoch = try secureDirectory.readPersistedClearEpoch()
        let issued = try currentIssuedAuthorityLocked(for: key)
        return KeyAuthoritySnapshot(clearEpoch: epoch, issuedAuthorityID: issued)
    }

    /// The named result of ``currentKeyAuthority(for:)`` -- see that
    /// method's own doc comment for why both fields must always be read
    /// together, under one lock hold.
    struct KeyAuthoritySnapshot: Sendable, Equatable {
        let clearEpoch: Int
        let issuedAuthorityID: AuthorityID
    }

    /// Durably issues and returns a fresh ``AuthorityID`` for `key`:
    /// reads the current record, mints a brand-new 128-bit random
    /// identifier (via ``mintFreshAuthorityIDLocked(distinctFrom:)``,
    /// which bounds its own retries and rejects the reserved pristine
    /// sentinel as well as either identifier this key's record already
    /// names), durably commits the record back with
    /// `issuedAuthorityID` replaced and `transitionRevision` advanced by
    /// exactly one (write, `fsync`, rename, directory `fsync`) while
    /// leaving `disposition` entirely untouched, and returns the new
    /// identifier alongside the revision that commit landed at.
    ///
    /// Called by ``beginIssuance(for:)`` and by
    /// `beginRevalidationIssuance(for:expectedClearEpoch:expectedAuthorityID:expectedContentHash:)`
    /// (one issuance per logical operation), and by
    /// ``resolvedMutationAuthorityLocked(for:token:)``'s unconditional
    /// (`token: nil`) branch alike: every call, from anywhere, returns a
    /// value no other call -- past, present, or future, in this process
    /// or any other -- will ever return again, for this or any other key.
    ///
    /// **A missing or pristine record is created here, and only here.**
    /// Issuance is the sole code path in this cache permitted to bring a
    /// key's authority record into existence; every mutation path fails
    /// closed on an absent record instead (see
    /// ``acceptToken(_:currentEpoch:currentIssued:)``). Creating it here
    /// is safe for exactly the reason this whole redesign exists: the
    /// identifier being recorded is freshly random, so it cannot
    /// resurrect, replay, or coincide with any authority a stale
    /// in-flight caller might still hold, regardless of whether the
    /// record was absent because this key is genuinely new or because a
    /// prior record was lost.
    ///
    /// **Proves this cache's disk budget on every single issuance, with
    /// no throttling.** A prior revision ran the full
    /// ``requireDiskWritesEnabledLocked()`` proof only on every 64th
    /// issuance within one actor instance, on the theory that a pure
    /// issuance-churn workload should not pay a full directory listing
    /// per small record write. That left a real gap the review flagged:
    /// the counter is process-local and starts at zero, so a sequence of
    /// short-lived service instances each performing fewer than 64
    /// operations would *never* run the full proof at all, and could keep
    /// growing this cache's physical footprint while genuinely over
    /// budget. Correctness wins here: the proof now runs unconditionally,
    /// which costs one directory listing per issuance (the same pass
    /// ``set(_:payload:metadata:token:)`` already performs on every
    /// content write) and removes the gap entirely.
    func issueAuthorityLocked(
        for key: AssetCacheKey,
        trackingOpenIssuance: Bool = true
    ) throws -> (authorityID: AuthorityID, revision: Int) {
        try requireDiskWritesEnabledLocked(requiringAuthorityRecordCapacity: true)
        let current = try currentAuthorityRecordLocked(for: key)
        let authorityID = try mintFreshAuthorityIDLocked(distinctFrom: current)
        let revision = try checkedAdvancedRevision(current.transitionRevision)
        let owner = trackingOpenIssuance ? try currentIssuanceOwnerLocked() : nil
        let currentWasLocallyOpen = current.openIssuanceOwnerID != nil
            && current.openIssuanceOwnerID == issuanceOwner?.identifier
        do {
            try commitAuthorityRecordLocked(
                KeyAuthorityRecord(
                    issuedAuthorityID: authorityID,
                    disposition: current.disposition,
                    transitionRevision: revision,
                    openIssuanceOwnerID: owner?.identifier
                ),
                for: key
            )
        } catch {
            releaseIssuanceOwnerIfUnusedLocked()
            throw error
        }
        if trackingOpenIssuance {
            locallyOpenIssuanceAuthorityIDs.insert(authorityID)
        }
        if currentWasLocallyOpen {
            retireLocallyOpenIssuanceLocked(current.issuedAuthorityID)
        }
        return (authorityID, revision)
    }

    /// How many times ``mintFreshAuthorityIDLocked(distinctFrom:)`` will
    /// draw a fresh candidate before giving up with a typed failure.
    ///
    /// Eight is ample precisely *because* no real draw is ever expected
    /// to be rejected: with 128 bits of entropy, a candidate colliding
    /// with either of the two identifiers this key's record currently
    /// names — or landing exactly on the reserved all-zero sentinel — is
    /// a `2^-128`-per-attempt event, so the probability of eight
    /// consecutive rejections is `2^-1024`-ish and is not a scenario this
    /// bound is sized against. The bound exists solely to convert
    /// "astronomically unlikely" into "provably terminates": a
    /// compromised, stuck, or (in tests) deliberately forced source that
    /// keeps returning a forbidden value must fail closed with an
    /// ordinary error rather than spin forever while holding this
    /// cache's cross-process exclusive lock.
    static let authorityIDMintAttemptLimit = 8

    /// Mints a brand-new ``AuthorityID`` for a key whose current durable
    /// record is `current`, rejecting and re-drawing any candidate that
    /// is not usable as a *fresh* authority.
    ///
    /// **This is the layer that enforces every candidate rule**, rather
    /// than ``AuthorityID/random()`` (which is deliberately a thin,
    /// policy-free wrapper over `SecRandomCopyBytes`): a candidate must
    /// not be ``AuthorityID/pristine`` (the reserved all-zero sentinel,
    /// which must only ever appear on a wholly pristine record and would
    /// otherwise be silently accepted by every exact-equality compare in
    /// this cache), must not equal the identifier already recorded as
    /// most recently *issued*, and must not equal the identifier of the
    /// currently *applied* disposition. The latter two matter for the
    /// same reason a fresh revalidation never reuses an entry's
    /// historical stamp: an issuance whose identifier coincides with an
    /// already-applied one is indistinguishable, to
    /// ``removeIfApplied(_:token:)``'s exact-match retraction contract,
    /// from "this exact operation's own mutation is what is applied".
    ///
    /// Fails closed with a typed
    /// ``AssetError/cachePersistenceFailed(_:)`` — never a trap, never an
    /// unbounded loop — if the bound is exhausted, and propagates the
    /// identical typed failure unchanged if the underlying random source
    /// itself reports an error at any attempt.
    func mintFreshAuthorityIDLocked(
        distinctFrom current: KeyAuthorityRecord
    ) throws -> AuthorityID {
        for _ in 0 ..< Self.authorityIDMintAttemptLimit {
            let candidate = try nextAuthorityIDCandidateLocked()
            guard
                candidate != .pristine,
                candidate != current.issuedAuthorityID,
                candidate != current.disposition.authorityID
            else {
                continue
            }
            return candidate
        }
        throw AssetError.cachePersistenceFailed(
            "Could not mint a usable cache authority identifier in" +
                " \(Self.authorityIDMintAttemptLimit) attempts; refusing to issue an operation" +
                " without a unique durable authority."
        )
    }

    /// One raw candidate draw: a test-forced value when this instance's
    /// ``AuthorityIDFaultInjectionState`` has one queued (or its forced
    /// hard failure), otherwise a genuine `SecRandomCopyBytes` draw. Inert
    /// in production, where the queue is always empty.
    private func nextAuthorityIDCandidateLocked() throws -> AuthorityID {
        if let forced = try authorityIDFaultState.nextForcedIdentifier() {
            return forced
        }
        return try AuthorityID.random()
    }
}
