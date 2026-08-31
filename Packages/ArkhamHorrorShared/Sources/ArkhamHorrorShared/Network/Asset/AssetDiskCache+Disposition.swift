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
    /// together — see this file's own type-level doc comment for why),
    /// reconciling its two independently-stored copies (the primary at
    /// ``AssetDiskCache/appliedTicketFilename(for:)`` and the mirror at
    /// ``AssetDiskCache/authorityRecordMirrorFilename(for:)`` — see that
    /// method's own doc comment for why a second copy exists at all).
    /// Must only ever be called while the caller already holds this
    /// instance's ``SecureCacheDirectory/acquireExclusiveLock()``.
    ///
    /// **Neither copy alone dictates the outcome.** A clean "both copies
    /// absent" miss is ``KeyAuthorityRecord/pristine`` — the only way
    /// this can legitimately occur for a key that has ever had anything
    /// durably committed for it is an independent loss of *both* copies
    /// at once, which this redundancy cannot, by itself, ever fully rule
    /// out (see ``AssetDiskCache/authorityRecordMirrorFilename(for:)``'s
    /// own doc comment). But if *either* copy alone is present, well
    /// formed, and passes ``isValidAuthorityRecord(_:)``'s structural
    /// invariants, that copy is trusted outright, **never** collapsed
    /// down to pristine merely because its sibling copy happens to be
    /// missing, corrupt, non-regular, oversized, or unparsable — exactly
    /// the single-point-of-failure defect a prior single-file (and, per
    /// a later review round, single-merged-file) design could not avoid.
    /// The missing/untrustworthy copy is then durably repaired
    /// (best-effort — see below) from the surviving one, so a *second*,
    /// independent loss is required before this same gap could ever
    /// reopen for this key.
    ///
    /// If *both* copies are present and individually valid but disagree,
    /// that can only mean a crash landed in the narrow window between
    /// ``commitAuthorityRecordLocked(_:for:)``'s two sequential writes —
    /// since a ticket/disposition for a single key only ever advances
    /// forward, never backward, the copy with the higher `issuedTicket`
    /// is unconditionally the newer, authoritative one; that value is
    /// re-committed to both copies before being returned, so a torn pair
    /// self-heals on its very next read rather than persisting
    /// indefinitely.
    ///
    /// **A copy that is present but fails to decode or validate is a
    /// fundamentally different signal than a copy that simply does not
    /// exist, and this deliberately never conflates the two.** A prior
    /// review round already established — and this round's own findings
    /// require preserving — that a present-but-unparsable/structurally-
    /// invalid authority record must always fail closed rather than ever
    /// being silently treated as absent: unlike a clean deletion (this
    /// round's own "disappearance" finding, which this redundancy exists
    /// to close), a torn/tampered/semantically-impossible record active
    /// evidence *against* trusting anything read from this root at all,
    /// including its sibling copy, so it is never allowed to fall back
    /// to that sibling. Only a copy that is cleanly ``.absent`` (the
    /// underlying file simply does not exist) may defer to its sibling;
    /// a `.corrupt` copy always throws.
    ///
    /// Repair writes throughout are deliberately best-effort: a failure
    /// to durably repair a missing/torn copy must never prevent
    /// returning an already-fully-valid, already-determined value — the
    /// repair only improves *future* reads' resilience, it is never a
    /// precondition for trusting the value this call itself just
    /// determined.
    func currentAuthorityRecordLocked(for key: AssetCacheKey) throws -> KeyAuthorityRecord {
        let primaryName = appliedTicketFilename(for: key)
        let mirrorName = authorityRecordMirrorFilename(for: key)
        let primary = try readAuthorityRecordCopyStateLocked(name: primaryName)
        let mirror = try readAuthorityRecordCopyStateLocked(name: mirrorName)
        switch (primary, mirror) {
        case (.corrupt, _), (_, .corrupt):
            throw AssetError.cachePersistenceFailed(
                "Authority record for this key is present but cannot be trusted; refusing to"
                    + " fall back to any sibling copy."
            )
        case (.absent, .absent):
            return .pristine
        case let (.valid(record), .absent):
            _ = try? writeAuthorityRecordFileLocked(record, name: mirrorName)
            return record
        case let (.absent, .valid(record)):
            _ = try? writeAuthorityRecordFileLocked(record, name: primaryName)
            return record
        case let (.valid(lhs), .valid(rhs)):
            guard lhs != rhs else { return lhs }
            let winner = lhs.issuedTicket >= rhs.issuedTicket ? lhs : rhs
            _ = try? commitAuthorityRecordLocked(winner, for: key)
            return winner
        }
    }

    /// The three mutually-exclusive states a single named on-disk
    /// authority-record copy can be in, from
    /// ``currentAuthorityRecordLocked(for:)``'s perspective — see that
    /// method's own doc comment for why `.absent` and `.corrupt` are
    /// deliberately never conflated into one another, unlike a prior
    /// design's collapsing of both into a single `nil`.
    private enum AuthorityRecordCopyState {
        /// The underlying file simply does not exist — a clean,
        /// unambiguous miss that may defer entirely to a sibling copy.
        case absent
        /// The underlying file exists but cannot be trusted (wrong
        /// type, oversized, unparsable JSON, or fails
        /// ``isValidAuthorityRecord(_:)``'s structural invariants) —
        /// active evidence against this specific copy that must never
        /// be silently overridden by falling back to a sibling.
        case corrupt
        case valid(KeyAuthorityRecord)
    }

    /// Reads and classifies a single named on-disk copy of `key`'s
    /// authority record into exactly one of
    /// ``AuthorityRecordCopyState``'s three cases. Throws only for a
    /// failure that has nothing to do with this specific copy's own
    /// trustworthiness at all (this method has none today — every
    /// `SecureCacheDirectory.read(name:maxBytes:)` failure mode this
    /// call distinguishes is itself evidence about *this* copy
    /// specifically) — kept `throws` purely so a future caller-visible
    /// failure mode never requires changing this method's own
    /// signature.
    private func readAuthorityRecordCopyStateLocked(
        name: String
    ) throws -> AuthorityRecordCopyState {
        // `SecureCacheDirectory.read(name:maxBytes:)` itself already
        // distinguishes a clean "does not exist" miss (`nil`) from every
        // other failure mode (wrong type, oversized, short/interrupted
        // read) by *throwing* for the latter -- deliberately propagated
        // here, unswallowed, rather than collapsed into `.absent`, since
        // those are exactly the kind of active anomaly that must fail
        // closed rather than ever defer to a sibling copy.
        guard let data = try secureDirectory.read(
            name: name,
            maxBytes: Self.maxDispositionBytes
        ) else {
            return .absent
        }
        guard let record = try? JSONDecoder.assetCache().decode(
            KeyAuthorityRecord.self,
            from: data
        ), isValidAuthorityRecord(record) else {
            return .corrupt
        }
        return .valid(record)
    }

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
    private func isValidAuthorityRecord(_ record: KeyAuthorityRecord) -> Bool {
        guard record.issuedTicket >= 0, record.disposition.ticket >= 0 else { return false }
        guard record.issuedTicket >= record.disposition.ticket else { return false }
        if record.disposition.ticket == 0 {
            guard record.disposition == .pristine else { return false }
        }
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
