import Foundation

/// Startup orphan/generation recovery and disk-quota eviction for
/// ``AssetDiskCache``, split out of `AssetDiskCache.swift` (which retains
/// `get`/`set`/`touch`/`remove` and the atomic-write primitives) purely to
/// stay under SwiftLint's `file_length`. Every filesystem operation here
/// goes through ``AssetDiskCache/directoryAccess``, the same verified,
/// descriptor-relative ``SecureCacheDirectory`` used by the rest of this
/// cache — never a `FileManager` path-string API, so recovery can never be
/// tricked into following a symlink planted at any entry name (including
/// the root directory being externally replaced between two recovery
/// passes: the held descriptor from `init` is reused unconditionally).
extension AssetDiskCache {
    /// Removes every payload file for `keyHash` except the one named for
    /// `keepingContentHash` (or every payload file for `keyHash` if `nil`),
    /// covering both a normal replacement's now-superseded prior generation
    /// and any extra stale generation(s) a previous crash left behind
    /// between a payload write and its metadata pointer commit. Best
    /// effort: an individual removal failure here does not change whether
    /// `keyHash` is servable again (`get` cannot serve any payload without
    /// a metadata pointer already having been confirmed removed by the
    /// caller) — it only risks a temporarily leaked file that a later
    /// recovery pass reclaims.
    func cleanupSupersededPayloads(
        forKeyHash keyHash: String,
        keeping keepingContentHash: String?
    ) {
        guard let names = try? directoryAccess.listNames() else { return }
        let prefix = "\(keyHash)."
        let keepName = keepingContentHash.map { payloadFilename(keyHash: keyHash, contentHash: $0) }
        for name in names {
            guard name.hasPrefix(prefix), name.hasSuffix(".bin"), name != keepName else { continue }
            _ = try? directoryAccess.remove(name: name)
        }
    }

    /// Runs once per cache instance lifetime (covering the common "cache
    /// created once at app launch" case, which is what makes this a real
    /// restart-recovery pass rather than a per-call cost). Removes any
    /// leftover `.tmp` file from an interrupted write, any metadata sidecar
    /// that fails to decode or validate, and any payload file not named
    /// for the exact content hash a currently valid metadata sidecar
    /// references. Also seeds ``AssetDiskCache``'s access-sequence
    /// allocator to resume strictly after the highest
    /// ``AssetCacheMetadata/accessSequence`` found among every currently
    /// valid persisted entry, so every value this process allocates
    /// afterward is guaranteed greater than every value already on disk —
    /// required for LRU order to survive a restart correctly.
    func recoverOrphansIfNeeded() {
        guard !didRecoverOrphans else { return }
        // Only mark recovery as done once the directory listing actually
        // succeeds. If listing fails (e.g. a transient I/O error),
        // `didRecoverOrphans` must stay `false` so the very next `set`
        // retries orphan/tmp cleanup instead of it being silently,
        // permanently disabled for the lifetime of this cache instance.
        guard let names = try? directoryAccess.listNames() else { return }
        didRecoverOrphans = true

        for name in names where name.hasSuffix(".tmp") {
            _ = try? directoryAccess.remove(name: name)
        }

        var referencedPayloadFilenames: Set<String> = []
        var highestAccessSequence: Int?
        for name in names where name.hasSuffix(".meta.json") {
            let keyHash = String(name.dropLast(".meta.json".count))
            guard
                let data = try? directoryAccess.read(
                    name: name,
                    maxBytes: SecureCacheDirectory.maxMetadataBytes
                ),
                let metadata = try? JSONDecoder.assetCache().decode(
                    AssetCacheMetadata.self,
                    from: data
                ),
                metadata.schemaVersion == AssetCacheMetadata.currentSchemaVersion,
                metadata.cacheKeyHex == keyHash,
                Self.isValidContentHash(metadata.payloadSHA256Hex)
            else {
                _ = try? directoryAccess.remove(name: name)
                continue
            }
            let referencedPayloadName = payloadFilename(
                keyHash: keyHash,
                contentHash: metadata.payloadSHA256Hex
            )
            // A metadata sidecar whose referenced payload file does not
            // actually exist on disk is itself an orphan (e.g. left
            // behind by a crash between the metadata commit and a
            // previous, separately-crashed payload write, or by external
            // tampering) — quarantine it too, rather than leaving it to
            // be discovered only the next time this exact key is read.
            guard (try? directoryAccess.attributes(name: referencedPayloadName)) != nil else {
                _ = try? directoryAccess.remove(name: name)
                continue
            }
            referencedPayloadFilenames.insert(referencedPayloadName)
            highestAccessSequence = max(
                highestAccessSequence ?? metadata.accessSequence.value,
                metadata.accessSequence.value
            )
        }
        for name in names where name.hasSuffix(".bin") {
            guard !referencedPayloadFilenames.contains(name) else { continue }
            _ = try? directoryAccess.remove(name: name)
        }
        seedAccessSequenceAllocator(resumingAfter: highestAccessSequence)
    }

    // MARK: - Eviction

    /// One valid entry's identity, decoded metadata, and its metadata
    /// sidecar's exact serialized byte count (the same `Data` this decodes
    /// `metadata` from), so accounting never relies on an estimate for
    /// bytes that are actually persisted to disk.
    ///
    /// `payloadBytes` is likewise the actual on-disk payload file size (via
    /// a symlink-safe `fstatat`, never `metadata.encodedByteCount`): metadata
    /// is untrusted input, and if the payload file were ever larger than
    /// metadata claims — corruption, a partial write, or external
    /// modification — trusting the claimed size would let eviction
    /// undercount real disk usage until that exact key was next read via
    /// `get(_:)` and quarantined there. See ``get(_:)`` for the same
    /// actual-file-size check applied on the read path.
    struct Entry {
        let hash: String
        let metadata: AssetCacheMetadata
        let metadataBytes: Int
        let payloadBytes: Int
    }

    func entries() -> [Entry] {
        guard let names = try? directoryAccess.listNames() else { return [] }
        var result: [Entry] = []
        for name in names where name.hasSuffix(".meta.json") {
            let hash = String(name.dropLast(".meta.json".count))
            guard
                let data = try? directoryAccess.read(
                    name: name,
                    maxBytes: SecureCacheDirectory.maxMetadataBytes
                ),
                let metadata = try? JSONDecoder.assetCache().decode(
                    AssetCacheMetadata.self,
                    from: data
                )
            else {
                // An unreadable or undecodable sidecar can never be
                // corrected by itself; quarantining it here (rather than
                // merely skipping it) prevents it from silently occupying
                // disk space forever, uncounted against `diskBudgetBytes`
                // and unevictable, until its exact key happens to be
                // looked up again via `get(_:)`.
                _ = try? directoryAccess.remove(name: name)
                cleanupSupersededPayloads(forKeyHash: hash, keeping: nil)
                continue
            }
            guard metadata.schemaVersion == AssetCacheMetadata.currentSchemaVersion,
                  metadata.cacheKeyHex == hash,
                  Self.isValidContentHash(metadata.payloadSHA256Hex)
            else {
                _ = try? directoryAccess.remove(name: name)
                cleanupSupersededPayloads(forKeyHash: hash, keeping: nil)
                continue
            }
            let payloadName = payloadFilename(keyHash: hash, contentHash: metadata.payloadSHA256Hex)
            guard
                let attributes = try? directoryAccess.attributes(name: payloadName),
                attributes.isRegularFile,
                attributes.size <= limits.maxEncodedBytes
            else {
                _ = try? directoryAccess.remove(name: name)
                cleanupSupersededPayloads(forKeyHash: hash, keeping: nil)
                continue
            }
            result.append(
                Entry(
                    hash: hash,
                    metadata: metadata,
                    metadataBytes: data.count,
                    payloadBytes: attributes.size
                )
            )
        }
        return result
    }

    /// The exact bytes an entry counts against the disk quota: the real
    /// on-disk payload file size plus the real serialized size of its
    /// metadata sidecar file — never a fixed estimate, and never a value
    /// merely claimed by (untrusted) metadata.
    static func accountedBytes(for entry: Entry) -> Int {
        entry.payloadBytes + entry.metadataBytes
    }

    /// Evicts the least-recently-used entries (by
    /// ``AssetCacheMetadata/accessSequence``, tie-broken deterministically
    /// by the entry's own key hash — never filesystem `atime`, and never a
    /// wall-clock `Date`) until total accounted bytes falls to or below
    /// ``AssetCacheLimits/lowWaterMarkDiskBytes``. Quota accounting only
    /// ever subtracts an entry's bytes once *both* its payload and its
    /// metadata sidecar have been successfully removed: a failed removal
    /// leaves that entry's bytes fully counted (so quota accounting can
    /// never under-report real disk usage), and this method does not
    /// throw or stop early on an individual removal failure — it keeps
    /// evicting other entries so one unremovable entry can never mask
    /// eviction of everything else.
    func evictIfNeeded() {
        var current = entries()
        var total = current.reduce(0) { $0 + Self.accountedBytes(for: $1) }
        guard total > limits.highWaterMarkDiskBytes else { return }
        current.sort {
            $0.metadata.accessSequence != $1.metadata.accessSequence
                ? $0.metadata.accessSequence < $1.metadata.accessSequence
                : $0.hash < $1.hash
        }
        for entry in current {
            guard total > limits.lowWaterMarkDiskBytes else { break }
            let payloadName = payloadFilename(
                keyHash: entry.hash,
                contentHash: entry.metadata.payloadSHA256Hex
            )
            let metadataName = "\(entry.hash).meta.json"
            let payloadRemoved = (try? directoryAccess.remove(name: payloadName)) ?? false
            let metadataRemoved = (try? directoryAccess.remove(name: metadataName)) ?? false
            guard payloadRemoved, metadataRemoved else { continue }
            total -= Self.accountedBytes(for: entry)
        }
        try? directoryAccess.fsyncRootDirectory()
    }
}
