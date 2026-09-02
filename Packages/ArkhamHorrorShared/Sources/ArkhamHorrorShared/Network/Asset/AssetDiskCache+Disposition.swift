import Foundation

private enum KeyAuthorityRecordCodingKeys: String, CodingKey {
    case issuedAuthorityID
    case disposition
    case openIssuanceOwnerID
    case transitionRevision
}

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
///
/// ## Threat model
///
/// Stating plainly what this design does and does not defend against,
/// so no reader (or future reviewer) infers a guarantee that is not
/// being made.
///
/// **In scope, and defended:**
///
/// - **Process crashes and unclean shutdowns mid-write.** Every durable
///   write of this record follows one fixed atomic shape -- bounded temp
///   file, `fsync`, rename into place, directory `fsync` (see
///   ``AssetDiskCache/writeAuthorityRecordFileLocked(_:name:)``) -- so a
///   crash at any instant leaves either the complete previous record or
///   the complete new one, never a torn mixture.
/// - **Concurrent access from independent instances and processes.**
///   Every read and every commit happens inside this directory's own
///   cross-process exclusive lock (see
///   ``SecureCacheDirectory/acquireExclusiveLock()``), under ordinary
///   filesystem semantics, so two services sharing one directory agree
///   on write ordering for the same key.
/// - **Missing or corrupt on-disk state.** A record that is absent is
///   treated as "nothing has ever been issued for this key" -- safe
///   only because the next issuance mints an unpredictable identifier
///   (see ``AuthorityID``). A record that is present but untrustworthy
///   (wrong file type, oversized, unparsable, or structurally
///   impossible) is a hard, typed, fail-closed error. Neither is ever
///   silently repaired, and there is no second copy anywhere to repair
///   one from.
///
/// **Explicitly out of scope, and not claimed anywhere:** a privileged
/// or same-user actor directly manipulating files in this cache's own
/// directory, outside this cache's write path. That includes restoring
/// an older, well-formed, fully-committed snapshot of a `<hash>.applied`
/// file byte-for-byte (a backup or volume-snapshot rollback, a
/// deliberate copy-back, a compromised filesystem). **No purely local,
/// app-owned-filesystem storage scheme can detect that class of
/// tampering**: any additional artifact introduced to witness it -- a
/// mirror copy, an anchor, a witness file, a journal, a floor index --
/// lives in the very same directory and is therefore restorable by the
/// very same actor, in the very same way, so it moves the problem
/// rather than solving it. Distinguishing "this file was never touched
/// since we wrote it" from "this file was put back exactly as it looked
/// before" requires external attestation this app does not have.
/// (Restoring an old record is, in any case, no more powerful than
/// deleting it: a restored older record still cannot authorize any
/// token an attacker does not already hold, because
/// ``AssetDiskCache/acceptToken(_:currentEpoch:currentIssued:)``
/// compares unpredictable 128-bit identifiers for exact equality.) An
/// earlier revision of this subsystem grew four separate mechanisms
/// chasing exactly this; they are deleted, and must not creep back in
/// under a new name.
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

        /// The advisory-lock session that owns the most recent issuance,
        /// or `nil` once that operation has reached a terminal outcome.
        /// A tombstone with a live owner remains unreclaimable because its
        /// operation may still lawfully publish.
        let openIssuanceOwnerID: AuthorityID?

        /// A counter advanced by exactly one on *every* durable commit
        /// this key's record ever undergoes -- a fresh issuance, a
        /// publish/touch, or either half of a two-phase retraction --
        /// never reset and never reused across two different commits.
        /// It totally orders this key's own commit history, which is
        /// what makes ``AssetDiskCache/commitAuthorityRecordLocked(_:for:)``'s
        /// checked-increment contract expressible at all, and what lets
        /// reclaim order the least-recently-touched records first (see
        /// ``AssetDiskCache/reconciledAuthorityRecordNames(_:)``).
        ///
        /// **It is not a tamper or rollback detector.** A durable
        /// restore of an older, well-formed snapshot of this same file
        /// by an actor outside this cache's write path is explicitly out
        /// of scope (see this file's "Threat model" section); the
        /// checked increment is a same-call-site consistency assertion,
        /// not a security control.
        let transitionRevision: Int

        init(
            issuedAuthorityID: AuthorityID,
            disposition: KeyDisposition,
            transitionRevision: Int,
            openIssuanceOwnerID: AuthorityID? = nil
        ) {
            self.issuedAuthorityID = issuedAuthorityID
            self.disposition = disposition
            self.transitionRevision = transitionRevision
            self.openIssuanceOwnerID = openIssuanceOwnerID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: KeyAuthorityRecordCodingKeys.self)
            issuedAuthorityID = try container.decode(
                AuthorityID.self,
                forKey: .issuedAuthorityID
            )
            disposition = try container.decode(
                KeyDisposition.self,
                forKey: .disposition
            )
            openIssuanceOwnerID = try container.decodeIfPresent(
                AuthorityID.self,
                forKey: .openIssuanceOwnerID
            )
            transitionRevision = try container.decode(Int.self, forKey: .transitionRevision)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: KeyAuthorityRecordCodingKeys.self)
            try container.encode(issuedAuthorityID, forKey: .issuedAuthorityID)
            try container.encode(disposition, forKey: .disposition)
            try container.encodeIfPresent(openIssuanceOwnerID, forKey: .openIssuanceOwnerID)
            try container.encode(transitionRevision, forKey: .transitionRevision)
        }

        /// The record a key that has never had any authority issued or
        /// mutation committed for it implicitly has.
        static let pristine = KeyAuthorityRecord(
            issuedAuthorityID: .pristine,
            disposition: .pristine,
            transitionRevision: 0,
            openIssuanceOwnerID: nil
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
    /// `issuedAuthorityID` and `disposition.authorityID`** beyond each
    /// one's own pristine-sentinel rule above. Two independently-minted
    /// random identifiers have no ordering, so
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
        guard hasValidAuthorityRecordIdentifiers(record) else { return false }
        guard (record.transitionRevision == 0) == (record == .pristine) else { return false }
        switch record.disposition.kind {
        case .content:
            return record.disposition.contentHash != nil
        case .retiring, .tombstone:
            return record.disposition.contentHash == nil
        }
    }

    private func hasValidAuthorityRecordIdentifiers(_ record: KeyAuthorityRecord) -> Bool {
        // The reserved all-zero sentinel may only ever appear on a record
        // that is pristine *in its entirety*. Checking each identifier
        // field against the whole-record pristine sentinel independently
        // is what closes a shape the whole-record equality check below
        // cannot see on its own: a record carrying
        // `issuedAuthorityID == .pristine` alongside a live `.content`
        // disposition and a nonzero revision is already `!= .pristine`
        // *because of that disposition*, so `(revision == 0) == (record
        // == .pristine)` is satisfied as `false == false` and the record
        // sails through -- even though its issued identifier is
        // illegally the one value no real mint can ever produce, and
        // therefore the one value ``acceptToken(_:currentEpoch:currentIssued:)``
        // relies on never matching a real caller's token.
        if record.issuedAuthorityID == .pristine {
            guard record == .pristine else { return false }
        }
        if record.disposition.authorityID == .pristine {
            guard record.disposition == .pristine else { return false }
        }
        if record.openIssuanceOwnerID == .pristine {
            return false
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
