import Foundation

/// A single, durable, cross-instance/cross-process monotonic LRU
/// access-sequence counter for one cache directory, replacing what was
/// previously a per-``AssetDiskCache``-actor-instance in-memory counter
/// (``AssetAccessSequenceAllocator``).
///
/// Before this type, each `AssetDiskCache` actor instance owned its own
/// private ``AssetAccessSequenceAllocator``, seeded once (at that
/// instance's own startup recovery) from the highest sequence value it
/// found among its own currently valid entries, and thereafter only ever
/// bumped to stay strictly after whatever value it personally observed
/// for *the exact entry it was currently touching* (see
/// ``AssetAccessSequenceAllocator/allocate(atLeastAfter:)``'s doc
/// comment). That closes the gap for repeated writes to *one* key, but
/// never for two *different* keys written by two different concurrently
/// live instances: instance A (seeded high, having recently written many
/// entries) and instance B (seeded low, perhaps only just constructed)
/// each allocate from their own independent, purely local counters, so a
/// key B writes *after* a key A already wrote can still be persisted with
/// a strictly *lower* sequence — silently corrupting the cache-wide LRU
/// eviction order across entries, exactly the defect a review flagged.
///
/// This type instead makes the durable counter itself, stored as its own
/// small file inside the verified cache root, the single source of truth:
/// every allocation reads the persisted value, computes the next value,
/// and durably persists it back, all while the caller already holds this
/// cache directory's cross-process ``SecureCacheDirectory/acquireExclusiveLock()``
/// — the same lock every other read-modify-write mutation in this package
/// already requires — so no additional synchronization is needed here.
/// Every allocation is therefore globally, cross-instance, cross-process
/// monotonic by construction, not merely monotonic per-entry.
extension SecureCacheDirectory {
    /// The fixed leaf name of this cache's durable access-sequence
    /// counter file, inside the verified root directory. Not `private`,
    /// for the same reason as ``lockFileName``: ``AssetDiskCache/removeAll()``
    /// must recognize and preserve this exact name across a whole-cache
    /// clear — the counter's own monotonicity must survive a clear (a
    /// freshly written entry after a clear must never be assigned a
    /// sequence value that could collide with, or sort before, one
    /// written before the clear) even though every actual cache entry is
    /// removed.
    static let accessSequenceFileName = ".arkham-cache.seq"

    /// Reads, computes, and durably persists this cache directory's next
    /// globally monotonic access-sequence value, returning it. Must only
    /// ever be called while the caller already holds this instance's
    /// ``acquireExclusiveLock()`` — see this type's own doc comment for
    /// why that alone is sufficient synchronization.
    ///
    /// - Parameter existingCandidate: the access sequence, if any,
    ///   already stamped on the specific entry this allocation is for
    ///   (read fresh from disk, under the same lock, immediately before
    ///   this call) — folded in purely so a single freshly-created cache
    ///   root (with no persisted counter file yet, `nil` from
    ///   ``readPersistedAccessSequence()``) does not regress below a
    ///   value some already-existing entry happens to carry; the counter
    ///   file itself, once it exists, is already authoritative on its
    ///   own and always wins once it is at least as large.
    ///
    /// Saturates at `Int.max` rather than wrapping to a negative value on
    /// overflow — see ``AssetAccessSequenceAllocator/allocate()``'s
    /// identical rationale — and, once saturated, never rewrites the
    /// counter file again for a further allocation past that point (there
    /// is nothing higher to persist), only for the very first allocation
    /// that reaches it.
    func allocateAccessSequence(
        atLeastAfter existingCandidate: AssetAccessSequence?
    ) throws -> AssetAccessSequence {
        let persisted = readPersistedAccessSequence()
        var base = persisted?.value ?? -1
        if let candidate = existingCandidate?.value, candidate > base {
            base = candidate
        }
        if base >= Int.max {
            if persisted?.value != Int.max {
                try persistAccessSequence(AssetAccessSequence(Int.max))
            }
            return AssetAccessSequence(Int.max)
        }
        let allocated = AssetAccessSequence(base + 1)
        try persistAccessSequence(allocated)
        return allocated
    }

    /// Ensures the durable counter is at least `floor`, persisting a
    /// bumped value only if it is not already. Called once per
    /// ``AssetDiskCache`` instance lifetime, during startup recovery,
    /// with the highest ``AssetCacheMetadata/accessSequence`` found among
    /// every currently valid persisted entry (a full-directory scan this
    /// type itself has no cheaper way to perform) — closing the gap for a
    /// cache directory created before this durable counter file existed
    /// (or one whose counter file was somehow lost/corrupted separately
    /// from its actual entries), so a fresh allocation immediately after
    /// recovery can never regress below a sequence value some entry
    /// already on disk carries, even though no single entry's own
    /// individual `atLeastAfter` floor alone could have caught that
    /// (each entry only floors against *itself*, never every other
    /// entry).
    func floorAccessSequence(atLeast floor: Int?) throws {
        guard let floor, floor >= 0 else { return }
        let persisted = readPersistedAccessSequence()?.value ?? -1
        guard floor > persisted else { return }
        try persistAccessSequence(AssetAccessSequence(floor))
    }

    /// Reads the currently persisted counter value, or `nil` if the file
    /// does not exist yet (a freshly created cache root) or cannot be
    /// parsed as a valid, fixed-width, non-negative access sequence (a
    /// corrupt or foreign file somehow planted at this exact name) --
    /// either case is folded into a single `nil`, matching
    /// ``allocateAccessSequence(atLeastAfter:)``'s own "treat as no prior
    /// value" fallback, which still cannot regress below whatever value
    /// the entry actually being written already carries, closing the gap
    /// a missing/corrupt counter file alone would otherwise reopen.
    func readPersistedAccessSequence() -> AssetAccessSequence? {
        guard let data = try? read(
            name: Self.accessSequenceFileName,
            maxBytes: AssetAccessSequence.digitWidth
        ), let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        guard string.utf8.count == AssetAccessSequence.digitWidth,
              string.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
              let parsed = Int(string)
        else {
            return nil
        }
        return AssetAccessSequence(parsed)
    }

    private func persistAccessSequence(_ sequence: AssetAccessSequence) throws {
        let tempName = Self.accessSequenceFileName + ".tmp"
        let data = Data(sequence.description.utf8)
        try writeTempAndFsync(tempName: tempName, data: data)
        try renameAndFsyncDirectory(from: tempName, to: Self.accessSequenceFileName)
    }
}
