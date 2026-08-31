import Foundation

/// This review round's finding #1, closed for good: a key's own three
/// per-key authority witnesses (primary, mirror, and issuance anchor --
/// see `AssetDiskCache+Disposition.swift`/`+IssuanceAnchor.swift`) are
/// all written by the *same* code, at the *same* time, under the *same*
/// lock, for the *same* key -- which makes them, together, still only
/// **one** witness against the one failure mode that matters most: a
/// fault (or deliberate interference) that strikes all three of that one
/// key's own files at once (deleting them together, or replacing all
/// three with an earlier, individually well-formed snapshot) is
/// completely undetectable from inside that key's own files alone,
/// because there is nothing left, anywhere in that key's own namespace,
/// to notice the loss.
///
/// This file adds a **fourth witness that is not part of that key's own
/// namespace at all**: one single, root-level, shared index file,
/// listing the highest ticket ever durably issued for *every* key this
/// whole cache directory has ever touched. A fault that deletes or rolls
/// back one specific key's own three files cannot, by construction, also
/// touch this file -- it is not named after that key, and nothing in
/// this cache ever writes to it as a side effect of writing to a
/// per-key file. That structural independence is what makes it a
/// trustworthy witness precisely in the one scenario the per-key
/// anchor/mirror pair cannot ever cover.
///
/// **Bound to the durable clear epoch, exactly like the issuance anchor
/// -- but never silently re-bootstrapped merely because it happens to be
/// missing.** Unlike the anchor (whose own "absent, so not yet binding"
/// branch is safe precisely because a *torn* anchor plus a
/// *consistent, agreeing* primary/mirror pair is still independently
/// impossible to forge -- see `AssetDiskCache+IssuanceAnchor.swift`'s own
/// doc comment), this index's whole purpose is to be the one place a
/// consistent-but-stale primary/mirror/anchor trio for one key can still
/// be caught. Treating its own absence as "not yet binding, safe to
/// silently create" would reopen exactly the hole it exists to close:
/// deleting (or never having created) this one file, on top of a single
/// key's own three files, would let that key silently re-bootstrap the
/// index as pristine for that key specifically, right back to where this
/// whole design started. It is instead bootstrapped **exactly once**,
/// only at the moment a root is independently, durably proven to be
/// genuinely fresh (see `AssetDiskCache+RootAuthority.swift`), and reset
/// only as part of the exact same durable transaction that legitimately
/// revokes every key's prior authority at once
/// (``AssetDiskCache/removeAll()``, via ``resetKeyUsageFloorIndexLocked(epoch:)``,
/// committed in the same critical section as
/// ``SecureCacheDirectory/bumpClearEpoch()``). Any *other* absence --
/// this file missing while at least one per-key authority file exists,
/// or while this instance has never itself just proven the root fresh --
/// is indistinguishable from "this index was lost or tampered with" and
/// is treated with exactly the same fail-closed policy this package
/// already applies to an old-format (pre-index) authority record: an
/// acceptable, typed, cold-miss failure for this still-unshipped,
/// pre-release local disk cache, never a silent re-bootstrap.
///
/// **Bounded and compacted, never left to grow by one permanent entry
/// per key for the lifetime of this cache directory.** Every entry this
/// index ever records is reclaimable the instant two things are both
/// true: this cache's own durable authority record for that exact key
/// has reached ``KeyDispositionKind/tombstone`` (there is no live
/// content left to protect), and every ticket this whole cache directory
/// will ever issue in the future is drawn from a single, cross-key,
/// never-repeating global sequence (``SecureCacheDirectory/allocateGlobalTicket()``,
/// `SecureCacheDirectory+TicketSequence.swift`) rather than from that one
/// key's own now-forgotten history -- see that file's own doc comment
/// for why forgetting a settled key's own high-water mark can never,
/// under that scheme, let a future reissuance for that same key collide
/// with a ticket this cache has already handed out. See
/// ``AssetDiskCache/evictIfNeeded()`` for where that reclamation actually
/// runs, folded into this cache's existing eviction pass.
extension AssetDiskCache {
    /// The fixed leaf name of this cache directory's single, shared,
    /// root-level key-usage floor index -- this whole file's own fourth
    /// witness. **Reserved across ``AssetDiskCache/removeAll()``'s own
    /// sweep** (added to that method's reserved-name list) rather than
    /// physically swept like every per-key file: a real clear must reset
    /// this index's *contents* (every key restarts with no recorded
    /// floor at all, exactly like every per-key file's own fresh start)
    /// without ever letting the file itself disappear entirely --
    /// disappearing here, unlike a per-key file disappearing, is
    /// permanently indistinguishable from "this index was lost", which
    /// would fail closed for *every* key this root has ever touched, not
    /// merely the one a real, legitimate clear was actually clearing.
    static let keyUsageFloorIndexFileName = ".arkham-cache.key-usage-floor"

    /// Bounds a read against a tampered or corrupt file of unbounded
    /// size, while remaining generous enough for
    /// ``maxKeyUsageFloorIndexEntries``-many small, fixed-shape entries
    /// (a 64-character hex key hash plus one small integer each) with
    /// ample headroom.
    static let maxKeyUsageFloorIndexBytes = 1 << 20

    /// The entry-count threshold above which ``AssetDiskCache/evictIfNeeded()``
    /// attempts to compact this index -- see
    /// ``compactKeyUsageFloorIfNeededLocked(names:)``.
    static let maxKeyUsageFloorIndexEntries = 4096

    /// The entry count a compaction pass attempts to reduce back down to,
    /// once triggered -- deliberately lower than
    /// ``maxKeyUsageFloorIndexEntries`` so a compaction pass has real
    /// headroom to work with, rather than immediately re-triggering on
    /// the very next commit.
    static let keyUsageFloorIndexCompactionTarget = 3072

    /// This index's own single entry for one key: the highest ticket
    /// ``AssetDiskCache/issueTicketLocked(for:)`` has ever durably
    /// reserved for it, recorded independently of -- and, by
    /// construction (see ``commitKeyUsageFloorLocked(for:issuedTicket:)``'s
    /// own doc comment), always committed strictly *before* -- that same
    /// value ever reaches that key's own issuance anchor, mirror, or
    /// primary copy.
    struct KeyUsageFloorEntry: Codable, Sendable, Equatable {
        let issuedTicket: Int
    }

    /// The full durable root-level index: every currently-tracked key's
    /// own floor entry, keyed by ``AssetCacheKey/digestHex``, alongside
    /// the durable clear epoch this snapshot was recorded under (mirrors
    /// ``KeyIssuanceAnchor/epoch``'s identical role: an index left over
    /// from before a legitimate clear is no longer binding the instant
    /// its own recorded epoch no longer matches -- though, unlike the
    /// anchor, this index is never merely "not yet binding" on a stale
    /// epoch, it is durably *reset* to a fresh, empty index at the exact
    /// same moment ``SecureCacheDirectory/bumpClearEpoch()`` itself
    /// commits, so a stale-epoch index should never actually be
    /// observed in practice -- see ``resetKeyUsageFloorIndexLocked(epoch:)``).
    struct KeyUsageFloorIndex: Codable, Sendable, Equatable {
        let epoch: Int
        var entries: [String: KeyUsageFloorEntry]

        static func empty(epoch: Int) -> KeyUsageFloorIndex {
            KeyUsageFloorIndex(epoch: epoch, entries: [:])
        }
    }

    /// Mirrors ``AuthorityRecordCopyState``'s/`IssuanceAnchorCopyState`'s
    /// identical three-way split, for the identical reason: a cleanly
    /// absent index and a present-but-untrustworthy one must never be
    /// conflated, since only the former may ever be silently bootstrapped
    /// (and only at genuine root-freshness, per this file's own
    /// type-level doc comment) while the latter is active evidence that
    /// must fail closed.
    enum KeyUsageFloorIndexState {
        case absent
        case corrupt
        case valid(KeyUsageFloorIndex)
    }

    /// The exact on-disk identity ``readKeyUsageFloorIndexStateLocked()``/
    /// ``writeKeyUsageFloorIndexLocked(_:)`` use to decide whether
    /// ``AssetDiskCache/keyUsageFloorIndexCache`` still reflects the file
    /// currently sitting at ``AssetDiskCache/keyUsageFloorIndexFileName``.
    /// `inode` alone already changes on every successful write (this
    /// file is always replaced via write-temp-then-`rename`, never
    /// edited in place, so a fresh write always yields a fresh inode);
    /// `modifiedAtNanoseconds` and `size` are carried alongside purely as
    /// cheap, independent corroboration -- inode numbers are reused once
    /// a filesystem frees them, however unlikely a collision with a
    /// stale cached value may be in practice for one root directory's
    /// own single well-known file.
    struct KeyUsageFloorIndexIdentity: Equatable {
        let inode: UInt64
        let modifiedAtNanoseconds: Int64
        let size: Int
    }

    func readKeyUsageFloorIndexStateLocked() throws -> KeyUsageFloorIndexState {
        guard let attributes = try secureDirectory.attributes(
            name: Self.keyUsageFloorIndexFileName
        ) else {
            keyUsageFloorIndexCache = nil
            return .absent
        }
        let identity = KeyUsageFloorIndexIdentity(
            inode: attributes.inode,
            modifiedAtNanoseconds: attributes.modifiedAtNanoseconds,
            size: attributes.size
        )
        if let cached = keyUsageFloorIndexCache, cached.identity == identity {
            return .valid(cached.index)
        }
        guard let data = try secureDirectory.read(
            name: Self.keyUsageFloorIndexFileName,
            maxBytes: Self.maxKeyUsageFloorIndexBytes
        ) else {
            keyUsageFloorIndexCache = nil
            return .absent
        }
        guard
            let index = try? JSONDecoder.assetCache().decode(KeyUsageFloorIndex.self, from: data),
            index.epoch >= 0,
            index.entries.values.allSatisfy({ $0.issuedTicket > 0 })
        else {
            keyUsageFloorIndexCache = nil
            return .corrupt
        }
        keyUsageFloorIndexCache = (identity: identity, index: index)
        return .valid(index)
    }

    func writeKeyUsageFloorIndexLocked(_ index: KeyUsageFloorIndex) throws {
        let data = try JSONEncoder.assetCache().encode(index)
        let tempName = Self.keyUsageFloorIndexFileName + ".tmp"
        try secureDirectory.writeTempAndFsync(tempName: tempName, data: data)
        try secureDirectory.renameAndFsyncDirectory(
            from: tempName,
            to: Self.keyUsageFloorIndexFileName
        )
        // Best-effort: re-`stat` the file we just renamed into place so
        // this actor's own very next read is a cache hit rather than a
        // redundant re-decode of the value already in hand. A failure
        // here only costs one future decode (the next read simply misses
        // and re-reads from disk) -- it must never be allowed to make
        // this write itself fail after it has already durably landed.
        guard let attributes = try? secureDirectory.attributes(
            name: Self.keyUsageFloorIndexFileName
        ) else {
            keyUsageFloorIndexCache = nil
            return
        }
        keyUsageFloorIndexCache = (
            identity: KeyUsageFloorIndexIdentity(
                inode: attributes.inode,
                modifiedAtNanoseconds: attributes.modifiedAtNanoseconds,
                size: attributes.size
            ),
            index: index
        )
    }

    /// Bootstraps a fresh, empty floor index -- **only** ever safe to
    /// call at the exact moment `AssetDiskCache+RootAuthority.swift`
    /// independently, durably proves this root's own authority
    /// (root-init marker + clear-epoch counter) was *just* created for
    /// the first time, never merely because this index itself happens to
    /// be absent (see this file's own type-level doc comment for why
    /// those two conditions are not the same thing). A **present, valid**
    /// index is left entirely untouched (idempotent against a caller that
    /// re-runs this after a partial crash between the root-authority
    /// commit and this call), and a **present but corrupt** one still
    /// fails closed even here -- a root that was just proven fresh can
    /// never simultaneously have a tampered/corrupt index already
    /// sitting in it; that combination is itself an anomaly, not a
    /// reason to overwrite silently.
    func bootstrapKeyUsageFloorIndexIfGenuinelyFreshLocked(epoch: Int) throws {
        switch try readKeyUsageFloorIndexStateLocked() {
        case .absent:
            try writeKeyUsageFloorIndexLocked(.empty(epoch: epoch))
        case .valid:
            return
        case .corrupt:
            throw AssetError.cachePersistenceFailed(
                "Key usage floor index is present but cannot be trusted on a root just" +
                    " proven fresh; refusing to silently overwrite it."
            )
        }
    }

    /// Durably resets this index back to empty -- called by
    /// ``AssetDiskCache/removeAll()`` in the exact same critical section,
    /// immediately after ``SecureCacheDirectory/bumpClearEpoch()`` itself
    /// commits, so every key's own floor entry is legitimately revoked at
    /// precisely the moment every key's own per-key authority is also
    /// revoked -- never merely swept away as an ordinary reserved-name
    /// exclusion the way a per-key file is.
    func resetKeyUsageFloorIndexLocked(epoch: Int) throws {
        try writeKeyUsageFloorIndexLocked(.empty(epoch: epoch))
    }

    /// Durably records `issuedTicket` as `key`'s own new floor entry --
    /// called by ``AssetDiskCache/commitAuthorityRecordLocked(_:for:)``
    /// **first**, strictly before that method's own anchor/mirror/primary
    /// writes (see that method's own doc comment for why this exact
    /// ordering is load-bearing): a crash landing after this call but
    /// before any of that method's other three writes lands is
    /// permanently, provably detectable on the very next read (this
    /// key's own reconciled primary/mirror/anchor result will read back
    /// *behind* this floor entry -- see
    /// ``enforceKeyUsageFloorLocked(_:for:)``) rather than silently
    /// accepted, exactly mirroring the anchor-first rationale this
    /// design already established for the anchor itself.
    ///
    /// Never regresses an existing entry: if this key already has a
    /// recorded floor ticket higher than `issuedTicket` (which can only
    /// ever mean this call itself is racing against its own already-
    /// completed effect, since every caller already holds this
    /// directory's exclusive lock and issuance is always sequential per
    /// key), this throws rather than silently accepting a lower value --
    /// the one invariant this whole index exists to enforce must never be
    /// violated by its own write path.
    ///
    /// Deliberately fails closed, rather than silently bootstrapping a
    /// fresh index, if this index itself is absent or corrupt at commit
    /// time: recreating it here would durably discard every *other*
    /// key's own already-recorded floor entries, reopening this design's
    /// whole closed gap for every key at once merely because one
    /// unrelated commit happened to run after the index was lost.
    func commitKeyUsageFloorLocked(for key: AssetCacheKey, issuedTicket: Int, epoch: Int) throws {
        guard issuedTicket > 0 else { return }
        guard case let .valid(index) = try readKeyUsageFloorIndexStateLocked() else {
            throw AssetError.cachePersistenceFailed(
                "Key usage floor index is missing or corrupt; refusing to record a fresh" +
                    " issuance without this cache's own root-level authority witness."
            )
        }
        guard index.epoch == epoch else {
            throw AssetError.cachePersistenceFailed(
                "Key usage floor index is stamped with a stale clear epoch at commit time," +
                    " which can never legitimately arise; refusing to record this issuance."
            )
        }
        var updated = index
        if let existing = updated.entries[key.digestHex] {
            guard issuedTicket >= existing.issuedTicket else {
                throw AssetError.cachePersistenceFailed(
                    "Key usage floor index already records a higher ticket for this key than" +
                        " the one just issued, which can never legitimately arise."
                )
            }
        }
        updated.entries[key.digestHex] = KeyUsageFloorEntry(issuedTicket: issuedTicket)
        try writeKeyUsageFloorIndexLocked(updated)
    }
}
