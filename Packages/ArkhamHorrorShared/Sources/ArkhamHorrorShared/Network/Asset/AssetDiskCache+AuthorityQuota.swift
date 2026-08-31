import Foundation

/// The **count** half of ``AssetDiskCache``'s disk quota: bounding how
/// many durable per-key authority records (`<hash>.applied`, see
/// `AssetDiskCache+Disposition.swift`) may exist at once, and reclaiming
/// the ones that are provably safe to delete. Split out of
/// `AssetDiskCache+Eviction.swift` (which owns the byte half) purely to
/// keep both within this package's `file_length`/`function_body_length`
/// conventions; every member here runs inside the same already-held
/// exclusive lock, in the same single directory listing, as that file's
/// ``evictIfNeeded()``.
///
/// **Why a count budget is needed at all.** One authority record is
/// durably written for every key that is ever *issued*, including keys
/// that never publish a single byte — a transport failure, a definitive
/// 404, a cancelled fetch. Those records are tiny, so a workload of many
/// thousands of distinct, never-republished keys barely moves
/// ``AssetCacheLimits/diskBudgetBytes`` while accumulating an unbounded
/// number of files, and, because every issuance now proves the budget
/// with a full directory listing, making every subsequent issuance
/// slower without limit. Before this, nothing short of
/// ``AssetDiskCache/removeAll()`` ever reclaimed one.
///
/// **What is safe to reclaim, and why.** A record whose current
/// ``AssetDiskCache/KeyDisposition/kind`` is
/// ``AssetDiskCache/KeyDispositionKind/tombstone`` is fully settled:
/// this key is confirmed absent, and nothing durably live refers to it.
/// That covers both a key that was genuinely published and then removed,
/// and a key that was only ever *issued* and never published (its
/// disposition is still the pristine `.tombstone` sentinel it inherited).
/// Deleting such a file collapses the key back to exactly the "no record
/// on disk" baseline a brand-new key already has, which this branch's
/// core invariant makes safe: the next issuance for that key mints a
/// brand-new, never-reused 128-bit random ``AuthorityID`` regardless of
/// what came before, so no future issuance can collide with a past one;
/// and any operation still holding a now-deleted authority's identifier
/// simply finds ``AssetDiskCache/acceptToken(_:currentEpoch:currentIssued:)``
/// rejecting it (the record reads back pristine, whose sentinel
/// identifier can never equal a real one) — the same safe "stale"
/// outcome losing a race to a newer legitimate issuance already
/// produces. A record whose kind is `.content` or `.retiring` is live or
/// mid-retraction and is **never** reclaimed here.
extension AssetDiskCache {
    /// The suffix of a key's single canonical durable authority record —
    /// see ``authorityRecordFilename(for:)``, which is the only place
    /// that builds one.
    static let authorityRecordFilenameSuffix = ".applied"

    /// One reclaimable record's name and the revision it last committed
    /// at, the ordering key reclaim uses.
    private struct ReclaimCandidate {
        let name: String
        let revision: Int
    }

    /// Enforces ``AssetCacheLimits/maxAuthorityRecordCount`` over an
    /// already-listed directory, returning the names that survive (for
    /// the byte-accounting pass that follows in ``evictIfNeeded()``), or
    /// `nil` to mean "this cache's state is not provably within budget",
    /// which the caller must treat exactly like an unenumerable listing:
    /// durably disable writes.
    ///
    /// Three outcomes, in order:
    ///
    /// 1. **Under the high-water mark:** returns `names` untouched, and —
    ///    deliberately — does *not* read a single record file. This is
    ///    what keeps the steady-state cost of the pass every issuance
    ///    performs to the directory listing it already paid for, instead
    ///    of a decode of every record on every call.
    /// 2. **Over the high-water mark:** every `.applied` file is read,
    ///    decoded, and validated. A file that cannot be read, decoded, or
    ///    validated — including a directory, FIFO, symlink, or oversized
    ///    file planted at an `.applied`-shaped name — is an accounting
    ///    and trust failure, never silently skipped as though it were not
    ///    there (`nil`), exactly as
    ///    ``sweepOrphanFiles(names:referencedPayloadFilenames:)`` and
    ///    ``accountedStrayCacheFileBytes(names:)`` already treat an
    ///    unaccountable stray. The reclaimable subset is then removed
    ///    oldest-revision-first until the count reaches
    ///    ``AssetCacheLimits/lowWaterMarkAuthorityRecordCount`` or no
    ///    candidates remain. A removal that physically fails leaves that
    ///    record still counted against the budget rather than silently
    ///    subtracted — the same convention the sibling content-eviction
    ///    loop applies to a failed `.bin`/`.meta.json` removal — and does
    ///    not stop the loop from reclaiming other candidates.
    /// 3. **Still over the high-water mark once every reclaimable record
    ///    is gone:** the surviving records are all live (`.content`/
    ///    `.retiring`) or physically unremovable, so this is a real,
    ///    uncorrectable over-cap condition and it fails closed (`nil`).
    ///
    /// Ordering by `transitionRevision` ascending mirrors how content
    /// eviction orders by ``AssetCacheMetadata/accessSequence``, with the
    /// honest caveat that the revision is *per key*, not a global clock:
    /// it orders "how much durable history this key has accumulated",
    /// which for a settled key is a reasonable stand-in for "least
    /// recently active", not a precise one. The hash-name tie-break makes
    /// the choice fully deterministic either way.
    ///
    /// No directory `fsync` is issued here: ``evictIfNeeded()`` performs
    /// exactly one for the whole pass after this returns, and treats a
    /// failure of it as "not provably durable" for these removals too.
    func reconciledAuthorityRecordNames(_ names: [String]) -> [String]? {
        var total = names.reduce(0) {
            $0 + ($1.hasSuffix(Self.authorityRecordFilenameSuffix) ? 1 : 0)
        }
        guard total > limits.highWaterMarkAuthorityRecordCount else { return names }
        guard let candidates = reclaimableAuthorityRecords(names: names) else { return nil }
        var reclaimed: Set<String> = []
        for candidate in candidates {
            guard total > limits.lowWaterMarkAuthorityRecordCount else { break }
            guard (try? directoryAccess.remove(name: candidate.name)) == true else { continue }
            reclaimed.insert(candidate.name)
            total -= 1
        }
        guard total <= limits.highWaterMarkAuthorityRecordCount else { return nil }
        guard !reclaimed.isEmpty else { return names }
        return names.filter { !reclaimed.contains($0) }
    }

    /// Every reclaimable (`.tombstone`) authority record in `names`,
    /// already sorted into the order reclaim must consume them, or `nil`
    /// if *any* `.applied` file could not be read, decoded, or validated.
    private func reclaimableAuthorityRecords(names: [String]) -> [ReclaimCandidate]? {
        var candidates: [ReclaimCandidate] = []
        for name in names where name.hasSuffix(Self.authorityRecordFilenameSuffix) {
            guard let record = validatedAuthorityRecordLocked(name: name) else { return nil }
            guard record.disposition.kind == .tombstone else { continue }
            candidates.append(
                ReclaimCandidate(name: name, revision: record.transitionRevision)
            )
        }
        candidates.sort {
            $0.revision != $1.revision ? $0.revision < $1.revision : $0.name < $1.name
        }
        return candidates
    }

    /// The record stored at the exact entry name `name`, or `nil` for any
    /// reason at all it cannot be trusted: absent, non-regular, wrongly
    /// owned, larger than ``maxDispositionBytes``, unparsable, or
    /// structurally impossible per ``isValidAuthorityRecord(_:)``. A
    /// by-name counterpart to ``currentAuthorityRecordLocked(for:)``,
    /// which is by-key and distinguishes a clean miss from a failure;
    /// here every non-record outcome is a failure, because the name came
    /// from a directory listing that just said the entry exists.
    private func validatedAuthorityRecordLocked(name: String) -> KeyAuthorityRecord? {
        guard
            let data = try? directoryAccess.read(
                name: name,
                maxBytes: Self.maxDispositionBytes
            ),
            let record = try? JSONDecoder.assetCache().decode(
                KeyAuthorityRecord.self,
                from: data
            ),
            isValidAuthorityRecord(record)
        else {
            return nil
        }
        return record
    }
}
