import Foundation

/// The durable, typed per-key **authority record** for ``AssetDiskCache``
/// -- one canonical file per key (`<hash>.applied`), written atomically,
/// carrying every piece of that key's own durable write-authority state
/// as a single unit: the identifier of the most recently *issued*
/// operation for the key (``AssetDiskCache/KeyAuthorityRecord/issuedAuthorityID``),
/// the key's currently *applied* typed disposition
/// (``AssetDiskCache/KeyAuthorityRecord/disposition``), and a
/// monotonically-advancing commit counter
/// (``AssetDiskCache/KeyAuthorityRecord/transitionRevision``).
///
/// **One file, no mirrors, no witnesses, no floors.** Earlier revisions
/// of this subsystem issued a per-key monotonically-increasing integer
/// "ticket" and then spent four separate mechanisms trying to prove that
/// counter had never been reconstructed after loss: a second mirror copy
/// of this record reconciled by revision, a per-key issuance anchor
/// witness file, a root-level non-replayable per-key usage floor index,
/// and a directory-global monotonic ticket sequence. All four existed
/// only because a counter's next value is *predictable*: if the durable
/// state that remembers it is lost, the very next issuance replays a
/// value some still-in-flight operation legitimately holds, and that
/// operation's compare-and-swap then wrongly succeeds. Issuing a
/// cryptographically-random 128-bit ``AuthorityID`` instead (see that
/// type's own doc comment) removes the predictability, and with it every
/// one of those mechanisms: a missing record is now unambiguously safe
/// to treat as "nothing has ever been issued for this key," because the
/// identifier minted next cannot match anything anyone still holds
/// regardless of *why* the record was missing.
///
/// A record that is *present but untrustworthy* (wrong file type,
/// oversized, unparsable JSON, or structurally impossible per
/// ``AssetDiskCache/isValidAuthorityRecord(_:)``) remains a hard, typed,
/// fail-closed failure -- it is never silently collapsed back to the
/// pristine baseline, and, because there is no second copy anywhere in
/// this design, it is never "repaired" from anything either.
///
/// Three disposition states, in the only order a key's disposition can
/// ever legally advance through for a given issued authority:
///
/// - ``KeyDispositionKind/content``: that authority's own mutation
///   durably published a payload+metadata pair; `contentHash` is that
///   payload's own ``AssetCacheMetadata/payloadSHA256Hex``.
/// - ``KeyDispositionKind/retiring``: that authority's own prior
///   `.content` disposition is being torn down (a definitive 404, or a
///   cancellation-triggered retraction of an abandoned publish) --
///   committed durably *before* the actual metadata/payload deletion is
///   even attempted, so a crash at any point during or after that
///   deletion attempt still leaves this key's own durable disposition
///   unambiguously distinct from a genuinely still-valid `.content`
///   entry. **Never served by ``AssetDiskCache/get(_:)`` regardless of
///   whether a metadata sidecar happens to still be physically
///   present**; it self-heals the instant any later mutation for this
///   exact key durably commits its own newer disposition over it.
/// - ``KeyDispositionKind/tombstone``: that authority's own removal has
///   fully completed (the destructive deletion attempt has been made,
///   successfully or not -- deletion itself is intentionally best-effort
///   once this final, durable state is what every read path trusts).
///   The *only* disposition a caller may treat as "this key is now
///   confirmed absent."
///
/// Stored at ``AssetDiskCache/authorityRecordFilename(for:)``
/// (`<hash>.applied`). This whole subsystem is pre-release, unshipped
/// software, so an on-disk format break needs no migration path: an
/// old-format file encountered by this code throws a typed, fail-closed
/// ``AssetError/cachePersistenceFailed(_:)``, an acceptable "treat this
/// key as if it had never been written" cold-miss outcome for a local,
/// ephemeral disk cache.
extension AssetDiskCache {
    enum KeyDispositionKind: String, Codable, Sendable, Equatable {
        case content
        case retiring
        case tombstone
    }

    /// See this file's own type-level doc comment for the full state
    /// machine this represents.
    struct KeyDisposition: Codable, Sendable, Equatable {
        /// The ``AuthorityID`` of the operation that committed this
        /// disposition. Equal to the enclosing record's
        /// ``KeyAuthorityRecord/issuedAuthorityID`` exactly when the
        /// most-recently-issued operation for this key is also the one
        /// whose mutation is currently applied; the two are otherwise
        /// independent values with no ordering relationship between
        /// them at all.
        let authorityID: AuthorityID
        let kind: KeyDispositionKind
        let contentHash: String?

        /// The disposition a key that has never had any mutation
        /// committed for it implicitly has -- the reserved all-zero
        /// ``AuthorityID/pristine`` identifier, which no real issuance
        /// can ever mint.
        static let pristine = KeyDisposition(
            authorityID: .pristine,
            kind: .tombstone,
            contentHash: nil
        )
    }

    /// The full durable per-key authority record, always read and written
    /// as one atomic unit. See this file's own type-level doc comment.
    struct KeyAuthorityRecord: Codable, Sendable, Equatable {
        /// The ``AuthorityID`` of the most recently *issued* operation
        /// for this key (``AssetDiskCache/issueAuthorityLocked(for:)``).
        /// This is the single value every mutation compare-and-swap
        /// compares a caller's token against, by exact equality -- see
        /// ``AssetDiskCache/acceptToken(_:currentEpoch:currentIssued:)``.
        let issuedAuthorityID: AuthorityID
        let disposition: KeyDisposition

        /// A counter advanced by exactly one on *every* durable commit
        /// this key's record ever undergoes -- a fresh issuance, a
        /// publish/touch, or either half of a two-phase retraction --
        /// never reset and never reused across two different commits.
        /// It totally orders this key's own commit history, which is
        /// what lets a durable rollback to an older-but-well-formed
        /// snapshot of this same record be detected (see
        /// ``AssetDiskCache/commitAuthorityRecordLocked(_:for:expecting:)``'s
        /// checked-increment contract) rather than silently accepted.
        let transitionRevision: Int

        /// The record a key that has never had any authority issued or
        /// mutation committed for it implicitly has.
        static let pristine = KeyAuthorityRecord(
            issuedAuthorityID: .pristine,
            disposition: .pristine,
            transitionRevision: 0
        )
    }

    /// Generous enough for this record's own small, fixed-shape JSON
    /// encoding (two 32-character hex identifiers, a revision counter, a
    /// short enum string, and an optional 64-hex-character content hash)
    /// with ample headroom, while still bounding a read against a
    /// tampered or corrupt file of unbounded size.
    static let maxDispositionBytes = 768

    /// Structural invariants every durably-decoded ``KeyAuthorityRecord``
    /// must satisfy before it is ever trusted -- rejecting a
    /// validly-JSON-encoded but semantically impossible value that a bare
    /// "did this decode as *some* `KeyAuthorityRecord`" check could never
    /// catch: a negative revision, the reserved pristine identifier
    /// paired with any disposition other than the exact
    /// ``KeyDisposition/pristine`` sentinel, a `.content` disposition
    /// carrying no content hash, or a `.retiring`/`.tombstone`
    /// disposition carrying one (kind/hash combinations that can never
    /// legitimately arise from this cache's own commit paths).
    ///
    /// **There is deliberately no cross-field check between
    /// `issuedAuthorityID` and `disposition.authorityID`.** Two
    /// independently-minted random identifiers have no ordering, so
    /// "issued is at least as new as applied" is not a statement this
    /// design can (or needs to) make: the two fields are simply
    /// independent, and are equal exactly when the currently-issued
    /// operation is also the currently-applied one. The predecessor
    /// design's `issuedTicket >= disposition.ticket` invariant existed
    /// only because both were drawn from the same ordered counter.
    ///
    /// `transitionRevision == 0` is reserved exclusively for
    /// ``KeyAuthorityRecord/pristine``: a record whose identifiers and
    /// disposition exactly match the pristine shape must carry revision
    /// `0`, and any other shape must carry revision `>= 1`. Every commit
    /// path unconditionally advances the revision, so either mismatch is
    /// impossible to reach legitimately and is rejected here exactly like
    /// every other impossible pairing above.
    func isValidAuthorityRecord(_ record: KeyAuthorityRecord) -> Bool {
        guard record.transitionRevision >= 0 else { return false }
        if record.disposition.authorityID == .pristine {
            guard record.disposition == .pristine else { return false }
        }
        guard (record.transitionRevision == 0) == (record == .pristine) else { return false }
        switch record.disposition.kind {
        case .content:
            guard record.disposition.contentHash != nil else { return false }
        case .retiring, .tombstone:
            guard record.disposition.contentHash == nil else { return false }
        }
        return true
    }

    /// `transitionRevision` is advanced by exactly one on every durable
    /// commit a key ever undergoes, and a bare `+ 1` at an already-
    /// `Int.max` value traps the whole process rather than failing this
    /// one operation. Every call site that advances a key's own revision
    /// routes through this one checked helper instead, converting that
    /// trap into the identical typed, fail-closed
    /// ``AssetError/cachePersistenceFailed(_:)`` every other counter
    /// exhaustion in this cache already reports (see
    /// ``SecureCacheDirectory/bumpClearEpoch()``'s identical contract for
    /// the durable clear-epoch counter) -- a single key reaching
    /// `Int.max` commits in its own lifetime is astronomically unlikely
    /// for a local, ephemeral disk cache, but must still degrade to an
    /// ordinary typed error, never a crash.
    func checkedAdvancedRevision(_ current: Int) throws -> Int {
        let (next, overflowed) = current.addingReportingOverflow(1)
        guard !overflowed else {
            throw AssetError.cachePersistenceFailed(
                "This key's own authority revision counter is exhausted; refusing to wrap or" +
                    " crash on overflow."
            )
        }
        return next
    }

    /// The single, shared crash-consistency shape every durable write of
    /// this record follows: write a bounded temp file, `fsync` it, rename
    /// it into place, `fsync` the containing directory. A crash at any
    /// point leaves either the complete previous record or the complete
    /// new one at ``authorityRecordFilename(for:)`` -- never a torn or
    /// partially-written mixture of the two. There is exactly one such
    /// file per key, so there is no second copy for any code path
    /// anywhere in this cache to "repair" this one from.
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
