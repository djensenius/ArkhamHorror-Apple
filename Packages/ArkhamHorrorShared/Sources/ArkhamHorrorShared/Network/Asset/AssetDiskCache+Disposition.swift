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

        /// A strictly-increasing counter bumped by exactly one on
        /// *every* durable commit this record's own key ever undergoes —
        /// a fresh ticket issuance, a publish/touch, or either half of a
        /// two-phase retraction — never reset, and never itself reused
        /// across two different commits. Unlike `issuedTicket`/
        /// `disposition.ticket` (which can legitimately repeat: a
        /// content → retiring → tombstone cycle for one ticket keeps
        /// `disposition.ticket` fixed across three separate commits),
        /// `revision` totally orders every commit this key has ever
        /// durably undergone, which is exactly what's required to
        /// reconcile two individually-valid-but-disagreeing copies of
        /// this record correctly even when they happen to share the same
        /// ticket (see ``currentAuthorityRecordLocked(for:)``'s own doc
        /// comment for the concrete scenario a bare ticket-based
        /// tie-break cannot resolve) and to durably anchor this key's
        /// issuance against a second, independent witness (see
        /// `AssetDiskCache+IssuanceAnchor.swift`).
        let revision: Int

        /// The record a key that has never had any ticket issued or
        /// mutation committed for it implicitly has.
        static let pristine = KeyAuthorityRecord(
            issuedTicket: 0,
            disposition: .pristine,
            revision: 0
        )
    }

    /// Generous enough for this record's own small, fixed-shape JSON
    /// encoding (an issuance ticket, a revision counter, a nested
    /// disposition ticket, a short enum string, and an optional
    /// 64-hex-character content hash) with ample headroom, while still
    /// bounding a read against a tampered or corrupt file of unbounded
    /// size.
    static let maxDispositionBytes = 768

    /// See `AssetDiskCache+DispositionReconciliation.swift` for how
    /// this record's two independently-stored on-disk copies (the
    /// primary and the mirror) are read, classified, and reconciled
    /// into one trusted value, then cross-checked against `key`'s own
    /// durable issuance anchor (`AssetDiskCache+IssuanceAnchor.swift`).
    ///
    /// Structural invariants every durably-decoded ``KeyAuthorityRecord``
    /// must satisfy before it is ever trusted, independent of which of
    /// the two on-disk copies (primary or mirror) produced it —
    /// rejecting a validly-JSON-encoded but semantically impossible
    /// value that a bare "did this decode as *some* `KeyAuthorityRecord`"
    /// check could never catch: a negative ticket, an `issuedTicket`
    /// behind its own `disposition.ticket` (never legal — see
    /// ``KeyAuthorityRecord/issuedTicket``'s own doc comment), the
    /// reserved pristine ticket value `0` paired with any disposition
    /// other than the exact ``KeyDisposition/pristine`` sentinel, a
    /// `.content` disposition carrying no content hash, or a
    /// `.retiring`/`.tombstone` disposition carrying one (kind/hash
    /// combinations that can never legitimately arise from this cache's
    /// own commit paths — see ``commitPublicationLocked(for:ticket:contentHash:)``/
    /// ``commitRetractionLocked(for:token:destroy:)``).
    ///
    /// Deliberately permits `issuedTicket > disposition.ticket` with
    /// `disposition` still ``KeyDisposition/pristine``: a ticket can be
    /// durably issued (``issueTicketLocked(for:)``) well before — or
    /// even without ever — anything is actually applied for it, which is
    /// an entirely ordinary, legitimate state, not evidence of
    /// corruption.
    ///
    /// Also validates `revision`: it must be non-negative, and — since
    /// `revision == 0` is reserved exclusively for
    /// ``KeyAuthorityRecord/pristine`` (a key that has never had a
    /// single commit) — a record whose `issuedTicket`/`disposition`
    /// otherwise exactly match the pristine shape must carry
    /// `revision == 0`, and conversely any *other* shape (anything ever
    /// actually issued or applied) must carry `revision >= 1`. A record
    /// claiming to be pristine at a nonzero revision, or claiming a
    /// zero revision while showing real issued/applied state, can never
    /// legitimately arise from this cache's own commit paths (every
    /// commit unconditionally bumps `revision`) and is rejected here
    /// exactly like every other impossible kind/hash pairing above.
    ///
    /// Not `private`: `AssetDiskCache+IssuanceAnchor.swift` reuses this
    /// exact invariant to validate the `KeyAuthorityRecord` nested inside
    /// a decoded ``KeyIssuanceAnchor``, rather than duplicating it.
    func isValidAuthorityRecord(_ record: KeyAuthorityRecord) -> Bool {
        guard record.issuedTicket >= 0, record.disposition.ticket >= 0 else { return false }
        guard record.issuedTicket >= record.disposition.ticket else { return false }
        guard record.revision >= 0 else { return false }
        if record.disposition.ticket == 0 {
            guard record.disposition == .pristine else { return false }
        }
        let isPristineShape = record.issuedTicket == 0 && record.disposition == .pristine
        guard (record.revision == 0) == isPristineShape else { return false }
        switch record.disposition.kind {
        case .content:
            guard record.disposition.contentHash != nil else { return false }
        case .retiring, .tombstone:
            guard record.disposition.contentHash == nil else { return false }
        }
        return true
    }

    /// The single, shared crash-consistency shape (write bounded temp
    /// file, `fsync`, rename into place, `fsync` the containing
    /// directory) both ``commitAuthorityRecordLocked(_:for:)``'s two
    /// writes and ``currentAuthorityRecordLocked(for:)``'s best-effort
    /// single-copy repairs share, so there is exactly one place that
    /// shape is expressed for this record type.
    func writeAuthorityRecordFileLocked(
        _ record: KeyAuthorityRecord,
        name: String
    ) throws {
        let data = try JSONEncoder.assetCache().encode(record)
        let tempName = name + ".tmp"
        try secureDirectory.writeTempAndFsync(tempName: tempName, data: data)
        try secureDirectory.renameAndFsyncDirectory(from: tempName, to: name)
    }
}
