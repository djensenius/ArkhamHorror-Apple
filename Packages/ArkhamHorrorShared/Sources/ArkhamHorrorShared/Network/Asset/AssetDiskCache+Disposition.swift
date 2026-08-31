import Foundation

/// The durable, typed per-key **authority record** for ``AssetDiskCache``
/// -- what actually occupies the `<hash>.applied` file this cache has
/// always used, now carrying *both* halves of this key's own durable
/// mutation-ordering state in one atomically-written unit: the highest
/// ticket ever durably *issued* for this key
/// (``AssetDiskCache/KeyAuthorityRecord/issuedTicket``, previously its
/// own separate `<hash>.gen` file) and this key's own typed *applied*
/// disposition (``AssetDiskCache/KeyAuthorityRecord/disposition``,
/// carrying a typed *kind* alongside the applied ticket rather than a
/// bare integer).
///
/// **Closes this package's most persistent review finding, round two: a
/// key's issuance counter and its applied disposition, once stored as
/// two separate files, can be torn apart by any failure that manages to
/// delete/corrupt exactly one of them while leaving the other
/// untouched — indistinguishable, from either file alone, from a
/// genuinely pristine key that never had a ticket issued for it at
/// all.** A prior revision of this cache split these two into
/// `<hash>.gen` (issuance) and `<hash>.applied` (disposition), each its
/// own independently-written file, guarded only by a cross-check
/// (`issued >= applied`) that catches one direction of that asymmetry
/// (a disposition somehow ahead of its own issuance counter) but not the
/// other: a ticket issued for a key that has never yet had anything
/// *applied* (its disposition is still genuinely
/// ``KeyDisposition/pristine``) writes only to `<hash>.gen` — if that
/// one file is later lost or corrupted independently (any I/O fault, or
/// external interference, that happens to strike only that one name),
/// the key reads back as if it had *never* had a ticket issued at all,
/// letting a fresh reservation silently replay a ticket number some
/// other, already-issued-but-not-yet-applied operation (in this process,
/// a sibling process, or this same process before a later crash) still
/// legitimately owns. Merging both halves into one file, written
/// atomically as a single unit at *every* durable state transition —
/// issuance included, not merely publication/retraction — removes this
/// asymmetry entirely: there is no longer any way for "issued" and
/// "applied" to independently diverge, because they are the same
/// on-disk artifact. A missing file is now unambiguously "no ticket has
/// ever been issued for this key" (the *only* way to reach that state);
/// a present-but-unparsable/wrong-type file is, as before, a hard,
/// typed, fail-closed failure rather than a silent collapse back to
/// that same pristine baseline.
///
/// Three disposition states, in the only order a key's disposition can
/// ever legally advance through for a given ticket:
///
/// - ``KeyDispositionKind/content``: `ticket`'s own mutation durably
///   published a payload+metadata pair; `contentHash` is that payload's
///   own ``AssetCacheMetadata/payloadSHA256Hex``.
/// - ``KeyDispositionKind/retiring``: `ticket`'s own prior `.content`
///   disposition is being torn down (a definitive 404, or a
///   cancellation-triggered retraction of an abandoned publish) --
///   committed durably *before* the actual metadata/payload deletion is
///   even attempted, so a crash (or any other failure) at any point
///   during or after that deletion attempt, but before the transition
///   below completes, still leaves this key's own durable disposition
///   unambiguously distinct from a genuinely still-valid `.content`
///   entry. **Never served by ``AssetDiskCache/get(_:)`` regardless of
///   whether a metadata sidecar happens to still be physically
///   present** -- an unresolved `.retiring` disposition is unreadable on
///   recovery (a fresh service instance, a sibling process, or this same
///   process after a restart), exactly like ``KeyDispositionKind/tombstone``
///   below; it self-heals the instant any *later* mutation for this
///   exact key (a fresh `set`/`touch`/`remove`) durably commits its own,
///   newer disposition over it, and physical cleanup of whatever bytes
///   it left behind remains best-effort, exactly as it always has been.
/// - ``KeyDispositionKind/tombstone``: `ticket`'s own removal has fully
///   completed (the destructive deletion attempt has been made,
///   successfully or not -- deletion itself is intentionally best-effort
///   once this final, durable state is what any caller/read path
///   actually trusts). This is the *only* disposition a caller may treat
///   as "this key is now confirmed absent" for the purposes of reporting
///   overall success or advancing a fallback candidate chain.
///
/// Stored at the exact same filename ``AssetDiskCache/appliedTicketFilename(for:)``
/// has always used (`<hash>.applied`) -- only the on-disk *format*
/// changes, from a bare disposition JSON object to this wrapping
/// record's own JSON encoding (which nests that same disposition object
/// under a new key). This is safe purely because this whole subsystem
/// is pre-release, unshipped software: an old-format file encountered by
/// this new code throws a typed, fail-closed
/// ``AssetError/cachePersistenceFailed(_:)`` (an acceptable "treat this
/// key as if it had never been written" cold-miss outcome for a local,
/// ephemeral disk cache), so no migration path is required. Reusing this
/// exact filename also means every existing reserved-name exclusion this
/// cache already maintains (`AssetDiskCache+Removal.swift`'s
/// `removeAll()` sweep, in particular) requires no further change at
/// all -- and means one fewer per-key file (`<hash>.gen` no longer
/// exists at all) is ever written for the lifetime of this cache
/// directory.
extension AssetDiskCache {
    enum KeyDispositionKind: String, Codable, Sendable, Equatable {
        case content
        case retiring
        case tombstone
    }

    /// See this file's own type-level doc comment for the full state
    /// machine this represents.
    struct KeyDisposition: Codable, Sendable, Equatable {
        let ticket: Int
        let kind: KeyDispositionKind
        let contentHash: String?

        /// The disposition a key that has never had any mutation
        /// committed for it implicitly has -- ticket `0` can never
        /// collide with any genuine historical ticket (the first one
        /// ``AssetDiskCache/issueTicketLocked(for:)`` ever reserves for
        /// any key is `1`), exactly like the bare-integer sentinel this
        /// replaces always relied on.
        static let pristine = KeyDisposition(ticket: 0, kind: .tombstone, contentHash: nil)
    }

    /// The full durable per-key authority record — both halves of a
    /// key's own durable mutation-ordering state, always read/written
    /// together as one atomic unit. See this file's own type-level doc
    /// comment for why splitting these two into separate files was
    /// itself the defect a prior review round found.
    struct KeyAuthorityRecord: Codable, Sendable, Equatable {
        /// The highest ticket ever durably reserved for this key via
        /// ``AssetDiskCache/issueTicketLocked(for:)`` — always `>=`
        /// `disposition.ticket`, by construction: every disposition
        /// commit reuses a ticket that was itself already issued (see
        /// ``AssetDiskCache/resolvedMutationTicketLocked(for:token:)``),
        /// never a value this record's own `issuedTicket` has not
        /// already advanced to.
        let issuedTicket: Int
        let disposition: KeyDisposition

        /// The record a key that has never had any ticket issued or
        /// mutation committed for it implicitly has.
        static let pristine = KeyAuthorityRecord(issuedTicket: 0, disposition: .pristine)
    }

    /// Generous enough for this record's own small, fixed-shape JSON
    /// encoding (an issuance ticket, a nested disposition ticket, a
    /// short enum string, and an optional 64-hex-character content hash)
    /// with ample headroom, while still bounding a read against a
    /// tampered or corrupt file of unbounded size.
    static let maxDispositionBytes = 512

    /// Reads `key`'s current durable authority record in full (both the
    /// highest-issued ticket and the applied disposition, always
    /// together — see this file's own type-level doc comment for why).
    /// Must only ever be called while the caller already holds this
    /// instance's ``SecureCacheDirectory/acquireExclusiveLock()``. A
    /// clean "does not exist" miss is ``KeyAuthorityRecord/pristine`` —
    /// the *only* way this can legitimately occur is a key that has
    /// never had a ticket issued or a mutation committed for it at all,
    /// since both halves have lived in this exact one file, written
    /// atomically together, from the moment either was first ever
    /// durably recorded. Any *other* failure (a symlink/non-regular
    /// entry at this name, an oversized or unparsable value — including
    /// a pre-merge bare-disposition or bare-integer file from before
    /// this type existed) is a hard, typed, fail-closed failure instead,
    /// since it means a real, previously persisted record exists but
    /// could not be trusted, which must never silently default back to
    /// the same baseline a pristine key would also report.
    func currentAuthorityRecordLocked(for key: AssetCacheKey) throws -> KeyAuthorityRecord {
        guard let data = try secureDirectory.read(
            name: appliedTicketFilename(for: key),
            maxBytes: Self.maxDispositionBytes
        ) else {
            return .pristine
        }
        guard let record = try? JSONDecoder.assetCache().decode(
            KeyAuthorityRecord.self,
            from: data
        ) else {
            throw AssetError.cachePersistenceFailed(
                "Key authority record '\(appliedTicketFilename(for: key))' is corrupt or unparsable"
            )
        }
        return record
    }

    /// The disposition half of ``currentAuthorityRecordLocked(for:)`` —
    /// kept as its own entry point since most callers only ever need
    /// this half, exactly like before this file's own issuance/
    /// disposition merge.
    func currentDispositionLocked(for key: AssetCacheKey) throws -> KeyDisposition {
        try currentAuthorityRecordLocked(for: key).disposition
    }

    /// Durably commits `record` as `key`'s new authority record in full:
    /// write a bounded temp file, `fsync` it, rename it into place,
    /// `fsync` the containing directory -- the identical crash-
    /// consistency shape every other durable single-file commit in this
    /// cache follows (see ``AssetDiskCache``'s own type-level doc
    /// comment). Must only ever be called while the caller already holds
    /// this instance's ``SecureCacheDirectory/acquireExclusiveLock()``.
    func commitAuthorityRecordLocked(
        _ record: KeyAuthorityRecord,
        for key: AssetCacheKey
    ) throws {
        let data = try JSONEncoder.assetCache().encode(record)
        let name = appliedTicketFilename(for: key)
        let tempName = name + ".tmp"
        try secureDirectory.writeTempAndFsync(tempName: tempName, data: data)
        try secureDirectory.renameAndFsyncDirectory(from: tempName, to: name)
    }

    /// Durably commits `disposition` as `key`'s new applied disposition,
    /// preserving this key's own currently-recorded `issuedTicket`
    /// (bumped up to at least `disposition.ticket`, which by
    /// construction — see ``resolvedMutationTicketLocked(for:token:)`` —
    /// can never itself exceed a ticket this key has not already been
    /// issued) rather than discarding it: every disposition commit
    /// re-reads the current record first specifically so this one
    /// write remains the single, atomic unit this file's own type-level
    /// doc comment requires — there is no window in which only the
    /// disposition half of this key's authority is durably updated
    /// while `issuedTicket` is not.
    func commitDispositionLocked(_ disposition: KeyDisposition, for key: AssetCacheKey) throws {
        let current = try currentAuthorityRecordLocked(for: key)
        try commitAuthorityRecordLocked(
            KeyAuthorityRecord(
                issuedTicket: max(current.issuedTicket, disposition.ticket),
                disposition: disposition
            ),
            for: key
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
