import Foundation

/// The compaction half of `AssetDiskCache+KeyUsageFloor.swift`'s own
/// root-level key usage floor index -- split into its own file purely
/// to keep that file within this package's length convention. See that
/// file's own type-level doc comment for the full reasoning this index
/// closes; this half is specifically this review round's finding #3:
/// the index must be bounded and reclaimed, never left to grow by one
/// permanent entry per key for the lifetime of this cache directory.
extension AssetDiskCache {
    /// The three fixed per-key authority filenames a genuinely
    /// ``KeyDispositionKind/tombstone``d, cold key's own compaction pass
    /// (``compactKeyUsageFloorIfNeededLocked(names:)``) reclaims together
    /// -- built directly from a raw digest-hex string (rather than
    /// requiring a full ``AssetCacheKey``) since this index itself never
    /// stores anything but that one, one-way hash.
    private func perKeyAuthorityFilenames(digestHex: String) -> [String] {
        ["\(digestHex).applied", "\(digestHex).applied-mirror", "\(digestHex).issuance-anchor"]
    }

    /// Reclaims this index's own oldest, confirmed-cold entries once
    /// entry count exceeds ``maxKeyUsageFloorIndexEntries`` -- folded
    /// into ``AssetDiskCache/evictIfNeeded()``'s existing single-listing
    /// eviction pass rather than run as its own separate directory scan.
    /// Returns the number of accounted bytes reclaimed (the physical size
    /// of every per-key file this pass actually deleted), so the caller
    /// can fold that back into its own running accounted-usage total; `0`
    /// if nothing was compacted (including if the index itself could not
    /// be safely read, which this method treats as "nothing safe to
    /// compact" rather than surfacing its own separate failure -- the
    /// existing ``AssetDiskCache/evictIfNeeded()`` accounting pass this
    /// runs alongside has already independently, separately proven or
    /// disproven the budget via its own read of this exact file).
    ///
    /// Per-candidate safety -- never removing a floor entry without also
    /// confirming, from that key's own still-physically-present files,
    /// that its disposition is genuinely `.tombstone` right now, and
    /// successfully deleting every one of that key's own three authority
    /// files in this exact same pass -- is factored out to
    /// ``reclaimKeyUsageFloorEntryIfSafeLocked(digestHex:names:)``, purely
    /// to keep this method's own body within this package's length/
    /// complexity convention.
    func compactKeyUsageFloorIfNeededLocked(names: Set<String>) -> Int {
        guard case let .valid(index) = (try? readKeyUsageFloorIndexStateLocked()) ?? .absent,
              index.entries.count > Self.maxKeyUsageFloorIndexEntries
        else {
            return 0
        }
        let currentEpoch = (try? secureDirectory.readPersistedClearEpoch()) ?? -1
        guard index.epoch == currentEpoch else { return 0 }
        let candidates = index.entries.sorted {
            $0.value.issuedTicket != $1.value.issuedTicket
                ? $0.value.issuedTicket < $1.value.issuedTicket
                : $0.key < $1.key
        }
        var updated = index
        var reclaimedBytes = 0
        for (digestHex, _) in candidates {
            guard updated.entries.count > Self.keyUsageFloorIndexCompactionTarget else { break }
            guard let bytes = reclaimKeyUsageFloorEntryIfSafeLocked(
                digestHex: digestHex,
                names: names
            ) else {
                continue
            }
            updated.entries.removeValue(forKey: digestHex)
            reclaimedBytes += bytes
        }
        guard reclaimedBytes > 0 else { return 0 }
        guard (try? writeKeyUsageFloorIndexLocked(updated)) != nil else { return 0 }
        return reclaimedBytes
    }

    /// Confirms `digestHex`'s own primary authority file is present
    /// (among `names`, this pass's own already-taken single directory
    /// listing), decodable, structurally valid, and genuinely
    /// ``KeyDispositionKind/tombstone``, then deletes every one of that
    /// key's own three authority files in this exact same call --
    /// returning the total bytes reclaimed, or `nil` if any part of that
    /// was not safely provable, in which case this key's own floor entry
    /// (and whatever of its own files still remain) is left entirely
    /// alone.
    private func reclaimKeyUsageFloorEntryIfSafeLocked(
        digestHex: String,
        names: Set<String>
    ) -> Int? {
        let primaryName = "\(digestHex).applied"
        guard names.contains(primaryName),
              let data = try? secureDirectory.read(
                  name: primaryName,
                  maxBytes: Self.maxDispositionBytes
              ),
              let record = try? JSONDecoder.assetCache().decode(
                  KeyAuthorityRecord.self,
                  from: data
              ),
              isValidAuthorityRecord(record),
              record.disposition.kind == .tombstone
        else {
            return nil
        }
        var reclaimedBytes = 0
        for name in perKeyAuthorityFilenames(digestHex: digestHex) {
            guard let bytes = removeAuthorityFileIfSafeLocked(name: name) else { return nil }
            reclaimedBytes += bytes
        }
        return reclaimedBytes
    }

    /// Removes exactly one authority file for a key already durably
    /// confirmed cold, returning the bytes reclaimed (`0` if the file was
    /// already absent, nothing to reclaim there specifically but still
    /// safe to continue), or `nil` if this one file could not be safely
    /// removed -- a non-regular entry (whose true size cannot be
    /// determined without walking into it) or an outright removal
    /// failure, either of which must leave this key's whole trio, and its
    /// floor entry, untouched rather than partially reclaimed.
    private func removeAuthorityFileIfSafeLocked(name: String) -> Int? {
        guard let attributes = try? secureDirectory.attributes(name: name) else {
            return 0
        }
        guard attributes.isRegularFile else { return nil }
        guard (try? secureDirectory.remove(name: name)) == true else { return nil }
        return attributes.size
    }
}
