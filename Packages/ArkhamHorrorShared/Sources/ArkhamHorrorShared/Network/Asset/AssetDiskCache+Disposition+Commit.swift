import Foundation

/// Split out of `AssetDiskCache+Disposition.swift` purely to stay under
/// this package's file-length lint limit. Contains the commit/mutation
/// side of the per-key authority record protocol that file's own
/// type-level doc comment introduces: durably committing a full
/// ``AssetDiskCache/KeyAuthorityRecord`` (both copies), resolving and
/// committing a single mutation's ticket, and the two commit entry
/// points every publish/touch/retraction actually calls. See that
/// file's own doc comment for the full reasoning; this file assumes it
/// as context.
extension AssetDiskCache {
    /// The disposition half of ``currentAuthorityRecordLocked(for:)`` —
    /// kept as its own entry point since most callers only ever need
    /// this half, exactly like before this file's own issuance/
    /// disposition merge.
    func currentDispositionLocked(for key: AssetCacheKey) throws -> KeyDisposition {
        try currentAuthorityRecordLocked(for: key).disposition
    }

    /// Durably commits `record` as `key`'s new authority record in full,
    /// to *both* of its independently-stored copies (see
    /// ``AssetDiskCache/authorityRecordMirrorFilename(for:)``'s own doc
    /// comment for why two copies exist at all) plus this key's own
    /// durable issuance anchor (``AssetDiskCache/issuanceAnchorFilename(for:)``,
    /// see `AssetDiskCache+IssuanceAnchor.swift`) — each written via the
    /// identical crash-consistency shape every other durable single-file
    /// commit in this cache follows (bounded temp file, `fsync`, rename
    /// into place, `fsync` the containing directory; see
    /// ``AssetDiskCache``'s own type-level doc comment), via
    /// ``writeAuthorityRecordFileLocked(_:name:)``/
    /// ``writeIssuanceAnchorFileLocked(_:name:)``. Must only ever be
    /// called while the caller already holds this instance's
    /// ``SecureCacheDirectory/acquireExclusiveLock()``.
    ///
    /// **Written in a fixed order -- anchor first, then mirror, then
    /// primary -- and this order is load-bearing, not arbitrary.** The
    /// mirror-before-primary half is what lets
    /// ``currentAuthorityRecordLocked(for:)``'s own reconciliation of two
    /// individually-valid-but-disagreeing copies always resolve
    /// correctly, by picking whichever copy has the higher `revision` —
    /// see that method's own doc comment. The anchor-then-mirror-then-
    /// primary half is what makes a crash landing *before* any of the
    /// remaining three writes even begins provably, permanently
    /// detectable: since this key's own exclusive lock (acquired by
    /// every caller before this method ever runs) fully serializes every
    /// commit for this key, the *only* way a future read can ever
    /// observe an earlier write in this sequence behind a later one is a
    /// crash landing inside this very call, between two of its own
    /// writes -- see `AssetDiskCache+IssuanceAnchor.swift`'s own
    /// type-level doc comment for why that specific window is left to
    /// fail closed rather than repaired.
    ///
    /// **Written floor-index-first, ahead of even the anchor.** The
    /// root-level key-usage floor index (`AssetDiskCache+KeyUsageFloor.swift`)
    /// is this whole authority design's own *fourth* witness, and the
    /// only one not stored inside this key's own per-key namespace at
    /// all -- see that file's type-level doc comment for why that
    /// structural independence is what actually closes this review
    /// round's finding #1 (all three of a key's own per-key files lost
    /// or rolled back *together*), a failure mode no per-key witness,
    /// however many redundant copies of itself, could ever detect on its
    /// **Written floor-index-first, ahead of even the anchor -- but
    /// only when `record.issuedTicket` is actually *new* relative to
    /// `priorIssuedTicket` (this exact key's own issued-ticket value
    /// immediately before this call, which every caller already has in
    /// hand from its own prior read of ``currentAuthorityRecordLocked(for:)``,
    /// the same read that already ran this key's own floor entry through
    /// ``enforceKeyUsageFloorLocked(_:for:anchorWasCurrentEpoch:)``'s own
    /// check).** The root-level key-usage floor index
    /// (`AssetDiskCache+KeyUsageFloor.swift`) is this whole authority
    /// design's own *fourth* witness, and the only one not stored inside
    /// this key's own per-key namespace at all -- see that file's
    /// type-level doc comment for why that structural independence is
    /// what actually closes this review round's finding #1 (all three of
    /// a key's own per-key files lost or rolled back *together*), a
    /// failure mode no per-key witness, however many redundant copies of
    /// itself, could ever detect on its own. Writing it first, ahead of
    /// the anchor, extends this exact same key's already-existing
    /// anchor-first crash-window guarantee one step further outward.
    ///
    /// **Skipping this step entirely when `record.issuedTicket <=
    /// priorIssuedTicket` is provably safe, not merely an optimization
    /// shortcut.** A disposition-only transition (``commitDispositionLocked(_:for:)``'s
    /// retiring/tombstone commits, which always reuse an already-issued
    /// ticket rather than minting a new one) never advances
    /// `issuedTicket` beyond what an *earlier* call already durably
    /// recorded in this exact same floor index, within the very same
    /// already-held exclusive lock -- there is nothing new for the floor
    /// to learn. Without this, every one of a single logical mutation's
    /// *three* separate `commitAuthorityRecordLocked` calls (one to
    /// reserve the ticket, one each for its `.retiring`/`.tombstone`
    /// disposition commits — see ``commitRetractionLocked(for:token:destroy:)``)
    /// would redundantly re-read, re-serialize, and re-`fsync` this
    /// cache's *entire* shared, root-level, all-keys floor index — whose
    /// own size scales with this whole directory's total distinct key
    /// count, not with any one operation — three times over for a single
    /// logical removal, turning what should be a handful of small,
    /// fixed-size per-key writes into a cost that scales with (and, once
    /// multiplied across many distinct keys, squares against) this
    /// cache's entire key population.
    func commitAuthorityRecordLocked(
        _ record: KeyAuthorityRecord,
        for key: AssetCacheKey,
        priorIssuedTicket: Int
    ) throws {
        let epoch = try secureDirectory.readPersistedClearEpoch()
        if record.issuedTicket > priorIssuedTicket {
            try commitKeyUsageFloorLocked(
                for: key,
                issuedTicket: record.issuedTicket,
                epoch: epoch
            )
        }
        try writeIssuanceAnchorFileLocked(
            KeyIssuanceAnchor(epoch: epoch, record: record),
            name: issuanceAnchorFilename(for: key)
        )
        try writeAuthorityRecordFileLocked(
            record,
            name: authorityRecordMirrorFilename(for: key)
        )
        try writeAuthorityRecordFileLocked(record, name: appliedTicketFilename(for: key))
    }

    /// Durably commits `disposition` as `key`'s new applied disposition,
    /// preserving this key's own currently-recorded `issuedTicket`
    /// (bumped up to at least `disposition.ticket`, which by
    /// construction — see ``resolvedMutationTicketLocked(for:token:)`` —
    /// can never itself exceed a ticket this key has not already been
    /// issued) rather than discarding it, and bumping `revision` by
    /// exactly one — every disposition commit re-reads the current
    /// record first specifically so this one write remains the single,
    /// atomic unit this file's own type-level doc comment requires —
    /// there is no window in which only part of this key's authority is
    /// durably updated while the rest is not.
    func commitDispositionLocked(_ disposition: KeyDisposition, for key: AssetCacheKey) throws {
        let current = try currentAuthorityRecordLocked(for: key)
        try commitAuthorityRecordLocked(
            KeyAuthorityRecord(
                issuedTicket: max(current.issuedTicket, disposition.ticket),
                disposition: disposition,
                revision: checkedAdvancedRevision(current.revision)
            ),
            for: key,
            priorIssuedTicket: current.issuedTicket
        )
    }

    /// The exact ticket a token-gated caller's own already-issued ticket
    /// resolves to, or a freshly reserved one for an unconditional
    /// (`token: nil`) caller -- shared dispatch logic every commit path
    /// below (``commitRetractionLocked(for:token:destroy:)``, and
    /// ``AssetDiskCache/set(_:payload:metadata:token:)``/
    /// ``AssetDiskCache/touch(_:metadata:token:)`` themselves, which each
    /// resolve their own ticket via this method *once* and reuse that
    /// exact value both to stamp
    /// ``AssetCacheMetadata/writeGenerationAtPublication`` before writing
    /// the metadata sidecar and to commit this key's disposition below --
    /// never resolving it a second, independent time, which for an
    /// unconditional caller would otherwise mint two different tickets
    /// for one logical write) uses identically to this cache's own prior
    /// `commitMutationTicketLocked(for:token:)` dispatch: a token-gated
    /// commit must always reuse its own already-accepted ticket verbatim,
    /// never mint a fresh one, since that fresh reservation would durably
    /// advance the shared issuance counter past whatever a different,
    /// already-issued-but-not-yet-applied operation for this same key
    /// legitimately relies on; an unconditional caller has no ticket of
    /// its own to reuse and must reserve a brand-new one so a *later*
    /// replay of a token issued *before* this call can never again
    /// satisfy ``AssetDiskCache/acceptToken(_:currentEpoch:currentIssued:)``'s
    /// `>=` against the unchanged prior disposition.
    func resolvedMutationTicketLocked(
        for key: AssetCacheKey,
        token: AssetCacheService.CacheToken?
    ) throws -> Int {
        if let ticket = token?.diskWriteGeneration {
            return ticket
        }
        return try issueTicketLocked(for: key)
    }

    /// Durably commits a `.content` disposition for `key` -- the
    /// counterpart, for a successful publish/touch, to
    /// ``commitRetractionLocked(for:token:destroy:)``'s two-phase
    /// removal. Used by ``AssetDiskCache/set(_:payload:metadata:token:)``/
    /// ``AssetDiskCache/touch(_:metadata:token:)`` immediately after their
    /// own payload/metadata-pointer commits have already durably landed
    /// -- both resolve `ticket` themselves (via
    /// ``resolvedMutationTicketLocked(for:token:)``, exactly once) before
    /// ever calling this, the identical value already stamped into the
    /// metadata sidecar they each just wrote, so this key's disposition
    /// and its metadata's own
    /// ``AssetCacheMetadata/writeGenerationAtPublication`` can never
    /// disagree regardless of whether `token` was supplied at all: an
    /// unconditional (`token: nil`) caller's own freshly reserved ticket
    /// is resolved only once and threaded through to both writes, never
    /// independently re-resolved here (which would mint a second,
    /// different ticket for the same logical write and desynchronize the
    /// two).
    @discardableResult
    func commitPublicationLocked(
        for key: AssetCacheKey,
        ticket: Int,
        contentHash: String
    ) throws -> Int {
        try commitDispositionLocked(
            KeyDisposition(ticket: ticket, kind: .content, contentHash: contentHash),
            for: key
        )
        return ticket
    }

    /// Durably commits a key's removal via the two-phase, crash-safe
    /// transition this file's own type-level doc comment describes:
    /// `.retiring(ticket)` *before* `destroy` ever runs, `.tombstone(ticket)`
    /// only once `destroy` has returned without throwing. Used by
    /// ``AssetDiskCache/remove(_:token:)`` (a definitive 404) as one
    /// single locked transaction -- unlike
    /// ``AssetDiskCache/beginRetraction(_:token:)``/
    /// ``AssetDiskCache/completeRetraction(_:token:)``, which durably
    /// commit that same `.retiring`-then-`.tombstone` pair of
    /// disposition transitions as two *separately lockable, separately
    /// awaitable* steps instead (so `AssetCacheService`'s own actor-level
    /// callers can await just the first before letting a waiter observe
    /// cancellation/staleness -- see ``beginRetraction(_:token:)``'s own
    /// doc comment) rather than a single all-in-one call through this
    /// method.
    ///
    /// Every durable state-write here (both disposition commits) always
    /// throws straight out on failure -- a caller that cannot durably
    /// confirm reaching `.tombstone` must never treat this as having
    /// succeeded: the disposition durably stays at `.retiring(ticket)`
    /// in that case, which is exactly as unreadable to
    /// ``AssetDiskCache/get(_:)`` as a confirmed tombstone, and which
    /// self-heals the instant a future mutation for this exact key
    /// commits its own newer disposition over it.
    ///
    /// `destroy` itself is `rethrows`: whether a failure inside it is
    /// fatal to this whole transaction is entirely up to the specific
    /// closure a caller supplies. ``remove(_:token:)``'s own closure
    /// never lets a physical deletion failure escape, since once this
    /// method's own final `.tombstone` commit lands, stale content is
    /// unreadable regardless of whatever bytes a failed deletion left
    /// physically present.
    @discardableResult
    func commitRetractionLocked(
        for key: AssetCacheKey,
        token: AssetCacheService.CacheToken?,
        destroy: () throws -> Void
    ) throws -> Int {
        let ticket = try resolvedMutationTicketLocked(for: key, token: token)
        try commitDispositionLocked(
            KeyDisposition(ticket: ticket, kind: .retiring, contentHash: nil),
            for: key
        )
        try destroy()
        try commitDispositionLocked(
            KeyDisposition(ticket: ticket, kind: .tombstone, contentHash: nil),
            for: key
        )
        return ticket
    }

    /// Test/diagnostic-only: a single, lock-acquiring read of `key`'s
    /// current durable disposition. Not used by any production code path
    /// -- every production caller either goes through
    /// `beginRevalidationIssuance`'s
    /// own atomic compare, or ``AssetDiskCache/get(_:)``'s own read-time
    /// gate -- but exposed so tests can assert on this exact durable
    /// state directly, rather than needing to infer it indirectly
    /// through some other primitive whose own contract has since changed
    /// to require more than a bare ticket match.
    func currentKeyDisposition(for key: AssetCacheKey) async throws -> KeyDisposition {
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        return try currentDispositionLocked(for: key)
    }
}
