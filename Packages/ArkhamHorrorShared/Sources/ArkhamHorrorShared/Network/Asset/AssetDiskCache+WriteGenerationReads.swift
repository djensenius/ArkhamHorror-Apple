import Foundation

/// The read/cross-check/issuance primitives for `key`'s durable
/// write-generation counter — split out of
/// `AssetDiskCache+WriteGeneration.swift` purely to keep that file
/// within this package's `file_length` convention. Every member here
/// must only ever be called while the caller already holds this
/// instance's own ``SecureCacheDirectory/acquireExclusiveLock()``,
/// exactly like the sibling file's own members.
extension AssetDiskCache {
    /// Reads `key`'s current durable issuance-ticket counter (the highest
    /// ticket ever reserved for `key`, by any caller). Must only ever be
    /// called while the caller already holds this instance's
    /// ``SecureCacheDirectory/acquireExclusiveLock()``.
    ///
    /// Simply the `issuedTicket` half of
    /// ``currentAuthorityRecordLocked(for:)``'s single merged record --
    /// see `AssetDiskCache+Disposition.swift`'s own type-level doc
    /// comment for why this counter and this key's applied disposition
    /// are always read from (and written to) that one file together, as
    /// one atomic unit, rather than as two independently-losable files.
    /// A clean "does not exist" miss is `0` -- a genuinely pristine key
    /// that has never had a ticket reserved for it has no prior value to
    /// compare against. Any *other* failure (a symlink/non-regular entry
    /// at this name, an oversized or unparsable value) is a hard, typed,
    /// fail-closed failure instead, since it means a real, previously
    /// persisted record exists but could not be trusted, which must
    /// never silently default back to the same baseline a pristine key
    /// would also report.
    func currentIssuedTicketLocked(for key: AssetCacheKey) throws -> Int {
        try currentAuthorityRecordLocked(for: key).issuedTicket
    }

    /// Reads `key`'s current durable *applied* ticket — the ticket half
    /// of ``currentDispositionLocked(for:)``'s full typed disposition
    /// (see `AssetDiskCache+Disposition.swift`'s type-level doc comment).
    /// Must only ever be called while the caller already holds this
    /// instance's ``SecureCacheDirectory/acquireExclusiveLock()``. A
    /// clean "does not exist" miss is `0` for the identical reason
    /// ``currentIssuedTicketLocked(for:)``'s own is: a genuinely pristine
    /// key has nothing applied yet.
    func currentAppliedTicketLocked(for key: AssetCacheKey) throws -> Int {
        try currentDispositionLocked(for: key).ticket
    }

    /// A single, atomic, cross-instance/cross-process authority snapshot
    /// for `key` — the durable clear epoch and this key's own highest
    /// durably *issued* ticket, read together under one exclusive-lock
    /// acquisition. Used by
    /// ``AssetCacheService/memoryEntryStillCurrent(_:storedGeneration:for:)``
    /// to decide whether an already-cached memory entry is still safe to
    /// serve without re-validating.
    ///
    /// **Deliberately reads the highest *issued* ticket, never merely the
    /// highest *applied* one, and the two fields are read together under
    /// one lock hold rather than as two separate, independently-locked
    /// calls.** An earlier revision instead read
    /// ``currentDurableClearEpoch()`` and a separate
    /// ``currentAppliedTicket(for:)`` call one after the other, each its
    /// own independent lock acquisition/release — a torn read: a sibling
    /// instance/process's whole-cache clear landing in the window between
    /// those two separately-locked reads could leave this call observing
    /// a pre-clear epoch paired with a post-clear (or vice versa)
    /// applied ticket, neither half actually describing the same durable
    /// moment in time. Comparing only against the highest *applied*
    /// ticket has a second, independent defect: a sibling service/process
    /// can *issue* (durably reserve, via ``issueTicketLocked(for:)``) a
    /// fresh ticket for this exact key the moment it begins a
    /// fetch/revalidation, strictly *before* that operation's own
    /// eventual mutation actually lands and advances the *applied*
    /// counter -- during that whole window, an applied-ticket-only
    /// comparison would keep reporting an older memory entry "still
    /// current" even though a strictly newer, already-in-flight operation
    /// for this exact key has already been issued and may complete with
    /// entirely different content (or a definitive removal) at any
    /// moment. Comparing against the highest *issued* ticket instead, with
    /// exact equality (not `>=`), rejects a memory hit the instant *any*
    /// newer operation for this key has been issued anywhere, regardless
    /// of whether that operation has itself completed yet -- the
    /// strictest safe comparison, matching
    /// ``AssetDiskCache/acceptToken(_:currentEpoch:currentIssued:)``'s own
    /// per-key fencing semantics exactly.
    func currentKeyAuthority(for key: AssetCacheKey) async throws -> KeyAuthoritySnapshot {
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        let epoch = try secureDirectory.readPersistedClearEpoch()
        let issuedTicket = try currentIssuedTicketLocked(for: key)
        return KeyAuthoritySnapshot(clearEpoch: epoch, issuedTicket: issuedTicket)
    }

    /// The named result of ``currentKeyAuthority(for:)`` — see that
    /// method's own doc comment for why both fields must always be read
    /// together, under one lock hold, rather than as two independently
    /// re-readable values.
    struct KeyAuthoritySnapshot: Sendable, Equatable {
        let clearEpoch: Int
        let issuedTicket: Int
    }

    /// Durably reserves and returns a fresh ticket for `key`: reads the
    /// current merged authority record, durably commits it back with
    /// `issuedTicket` bumped to its successor (write, `fsync`, rename,
    /// directory `fsync`) while leaving `disposition` entirely untouched,
    /// and returns that successor — never the pre-bump value. Called by
    /// ``beginIssuance(for:)`` (one reservation per logical operation's
    /// issuance) and by
    /// ``AssetDiskCache/resolvedMutationTicketLocked(for:token:)``'s own
    /// unconditional (`token: nil`) branch (one further reservation per
    /// actual committed mutation with no external token to reuse) alike:
    /// every single call to this method, from anywhere, returns a value
    /// no other call -- past, present, or future -- will ever return
    /// again for this key.
    ///
    /// **Writes the full merged record on every call, disposition
    /// included, not merely a bare counter** -- see
    /// `AssetDiskCache+Disposition.swift`'s own type-level doc comment
    /// for why this is precisely the change that makes the two-file
    /// split's independent-loss defect structurally impossible: an
    /// issuance that has not yet had anything applied for it durably
    /// records that fact (``KeyDisposition/pristine``) in the very same
    /// file as its own ticket, rather than leaving that ticket as the
    /// sole occupant of an entirely separate file with nothing else
    /// durably anchoring it.
    ///
    /// Guards against overflow: once already at `Int.max`, throws rather
    /// than silently colliding two genuinely different future tickets
    /// onto the same value.
    ///
    /// **Honors this cache's whole-cache disk-writes-disabled gate.**
    /// This round's finding #3: a prior revision let issuance proceed
    /// unconditionally, so a churn of unique, never-reused keys (each
    /// issuing a ticket that durably writes three permanent per-key
    /// authority files, plus this key's own floor-index entry) could
    /// keep growing this cache's own physical on-disk footprint even
    /// after ``requireDiskWritesEnabledLocked()`` had already durably
    /// disabled every *content* write for being over budget -- issuance
    /// itself was never gated the same way. Checking (and, periodically,
    /// via ``requireDiskWritesEnabledThrottledLocked()``'s own call to
    /// ``evictIfNeeded()``, re-proving) that gate here, as this method's
    /// very first step, closes that: no new ticket -- and so no new
    /// permanent per-key file -- can ever be durably reserved while this
    /// cache's own disk budget is already known not to be confirmed, and
    /// a pure-churn workload still has its own footprint bounded and
    /// re-checked periodically even if it never calls
    /// `set`/`touch` -- see that method's own doc comment for why the
    /// re-proof itself is throttled rather than run on every single call.
    ///
    /// **Draws its value from this directory's single, global,
    /// cross-key monotonic ticket sequence
    /// (``SecureCacheDirectory/allocateGlobalTicket()``,
    /// `SecureCacheDirectory+TicketSequence.swift`) rather than from this
    /// one key's own `issuedTicket + 1`.** This is what makes reclaiming
    /// (compacting away) a settled, cold key's own floor-index entry and
    /// per-key files safe at all (see
    /// `AssetDiskCache+KeyUsageFloor.swift`'s own type-level doc
    /// comment): since every ticket this whole cache directory will ever
    /// issue, for any key, is guaranteed strictly greater than every
    /// ticket it has issued before, a *future* reissuance for a key
    /// whose own past history has since been entirely forgotten can
    /// never collide with a value that history once held, regardless of
    /// what was forgotten. Still independently defended, never trusted
    /// on faith alone: this key's own currently-known `issuedTicket`
    /// (read fresh, from this key's own still-intact durable authority --
    /// entirely unaffected by anything the global sequence file itself
    /// may separately have lost or had reset) must be strictly less than
    /// the freshly allocated value, or this fails closed rather than
    /// ever durably recording a ticket this key's own record shows it
    /// has already reached or passed.
    ///
    /// **That floor is relaxed to `0` -- and the freshly-committed
    /// record's own `disposition` reset to ``KeyDisposition/pristine``
    /// rather than carried forward -- whenever this key's own current
    /// authority record is itself only a stale-epoch leftover (its
    /// issuance anchor never independently proved a real *current*-epoch
    /// commit landed; see
    /// ``AssetDiskCache/currentAuthorityRecordStatusLocked(for:)``'s own
    /// doc comment).** A whole-cache clear's durable epoch bump is what
    /// already, separately renders such a leftover non-authoritative
    /// (``AssetDiskCache/removeAll()`` durably bumps the clear epoch
    /// *before* its own best-effort physical sweep, so every one of this
    /// key's own three per-key files can survive a partially-failed
    /// sweep fully intact yet already fenced off) -- this cache's own
    /// single global ticket sequence is, by the same clear, legitimately
    /// reset right alongside it (see
    /// `SecureCacheDirectory+TicketSequence.swift`'s own doc comment for
    /// why that reset is itself both safe and desirable). Requiring a
    /// freshly allocated ticket to still exceed a leftover value the
    /// clear already fenced off would incorrectly re-bind it, permanently
    /// blocking every future re-issuance for any key a partially-failed
    /// `removeAll()` could not physically delete. Carrying that leftover
    /// record's own stale `disposition` (rather than resetting it) into
    /// this freshly-issued, now current-epoch-anchored record would be an
    /// even sharper hazard: ``commitAuthorityRecordLocked(_:for:)``
    /// durably re-anchors the record it is given at the *current* epoch
    /// unconditionally, so carrying forward a stale `.content` (or
    /// `.retiring`) disposition here would make a sibling reader's very
    /// next ``enforceIssuanceAnchorLocked(_:for:)`` call see a
    /// current-epoch anchor vouching for pre-clear content that nothing
    /// has actually republished under this fresh ticket at all --
    /// resurrecting exactly the stale bytes this whole mechanism exists
    /// to fence off. A key with no such leftover (`wasCurrentEpoch ==
    /// true`, the ordinary case) is entirely unaffected: its own real
    /// `issuedTicket`/`disposition` are used exactly as before.
    func issueTicketLocked(for key: AssetCacheKey) throws -> Int {
        try requireDiskWritesEnabledThrottledLocked()
        let status = try currentAuthorityRecordStatusLocked(for: key)
        let current = status.record
        guard current.issuedTicket < Int.max else {
            throw AssetError.cachePersistenceFailed(
                "Write-generation counter is exhausted for this key"
            )
        }
        let next = try secureDirectory.allocateGlobalTicket()
        let effectiveFloor = status.wasCurrentEpoch ? current.issuedTicket : 0
        guard next > effectiveFloor else {
            throw AssetError.cachePersistenceFailed(
                "Globally allocated ticket does not exceed this key's own already-known" +
                    " issued ticket; refusing to durably record a value this key's own" +
                    " authority record shows has already been reached or passed."
            )
        }
        let effectiveDisposition = status.wasCurrentEpoch ? current.disposition : .pristine
        try commitAuthorityRecordLocked(
            KeyAuthorityRecord(
                issuedTicket: next,
                disposition: effectiveDisposition,
                revision: checkedAdvancedRevision(current.revision)
            ),
            for: key,
            priorIssuedTicket: effectiveFloor
        )
        return next
    }
}
