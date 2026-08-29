import Foundation

/// Startup orphan/generation recovery and disk-quota eviction for
/// ``AssetDiskCache``, split out of `AssetDiskCache.swift` (which retains
/// `get`/`set`/`touch`/`remove` and the atomic-write primitives) purely to
/// stay under SwiftLint's `file_length`.
extension AssetDiskCache {
    // MARK: - Corruption / orphan recovery

    /// Removes every payload file for `keyHash` except the one named for
    /// `keepingContentHash` (or every payload file for `keyHash` if `nil`),
    /// covering both a normal replacement's now-superseded prior generation
    /// and any extra stale generation(s) a previous crash left behind
    /// between a payload write and its metadata pointer commit.
    func cleanupSupersededPayloads(
        forKeyHash keyHash: String,
        keeping keepingContentHash: String?
    ) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        else { return }
        let prefix = "\(keyHash)."
        let keepName = keepingContentHash.map { "\(keyHash).\($0).bin" }
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".bin"), name != keepName else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Runs once per cache instance lifetime (covering the common "cache
    /// created once at app launch" case, which is what makes this a real
    /// restart-recovery pass rather than a per-call cost). Removes any
    /// leftover `.tmp` file from an interrupted write, any metadata sidecar
    /// that fails to decode or validate, and any payload file not named
    /// for the exact content hash a currently valid metadata sidecar
    /// references (covering both fully orphaned payloads and superseded
    /// generations from an earlier crash between a payload write and its
    /// metadata pointer commit).
    func recoverOrphansIfNeeded() {
        guard !didRecoverOrphans else { return }
        // Only mark recovery as done once the directory listing actually
        // succeeds. If `contentsOfDirectory` fails (e.g. a transient I/O
        // error), `didRecoverOrphans` must stay `false` so the very next
        // `set` retries orphan/tmp cleanup instead of it being silently,
        // permanently disabled for the lifetime of this cache instance.
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        else { return }
        didRecoverOrphans = true

        for url in contents where url.lastPathComponent.hasSuffix(".tmp") {
            try? fileManager.removeItem(at: url)
        }

        var referencedPayloadFilenames: Set<String> = []
        for url in contents where url.lastPathComponent.hasSuffix(".meta.json") {
            let keyHash = String(url.lastPathComponent.dropLast(".meta.json".count))
            guard let data = try? Data(contentsOf: url),
                  let metadata = try? JSONDecoder.assetCache.decode(
                      AssetCacheMetadata.self,
                      from: data
                  ),
                  metadata.schemaVersion == AssetCacheMetadata.currentSchemaVersion,
                  metadata.cacheKeyHex == keyHash,
                  Self.isValidContentHash(metadata.payloadSHA256Hex)
            else {
                try? fileManager.removeItem(at: url)
                continue
            }
            let referencedPayloadURL = Self.payloadURL(
                in: directory,
                keyHash: keyHash,
                contentHash: metadata.payloadSHA256Hex
            )
            // A metadata sidecar whose referenced payload file does not
            // actually exist on disk is itself an orphan (e.g. left
            // behind by a crash between the metadata commit and a
            // previous, separately-crashed payload write, or by external
            // tampering) — quarantine it too, rather than leaving it to
            // be discovered only the next time this exact key is read.
            guard fileManager.fileExists(atPath: referencedPayloadURL.path) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            referencedPayloadFilenames.insert(referencedPayloadURL.lastPathComponent)
        }
        for url in contents where url.lastPathComponent.hasSuffix(".bin") {
            guard !referencedPayloadFilenames.contains(url.lastPathComponent) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Eviction

    /// One valid entry's identity, decoded metadata, and its metadata
    /// sidecar's exact serialized byte count (the same `Data` this decodes
    /// `metadata` from), so accounting never relies on an estimate for
    /// bytes that are actually persisted to disk.
    ///
    /// `payloadBytes` is likewise the actual on-disk payload file size (via
    /// filesystem attributes), not `metadata.encodedByteCount`: metadata is
    /// untrusted input, and if the payload file were ever larger than
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
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        else { return [] }
        var result: [Entry] = []
        for url in contents where url.lastPathComponent.hasSuffix(".meta.json") {
            let hash = String(url.lastPathComponent.dropLast(".meta.json".count))
            guard let data = try? Data(contentsOf: url),
                  let metadata = try? JSONDecoder.assetCache.decode(
                      AssetCacheMetadata.self,
                      from: data
                  )
            else {
                // An unreadable or undecodable sidecar can never be
                // corrected by itself; quarantining it here (rather than
                // merely skipping it) prevents it from silently occupying
                // disk space forever, uncounted against `diskBudgetBytes`
                // and unevictable, until its exact key happens to be
                // looked up again via `get(_:)`. Garbage metadata means no
                // generation for this key hash is currently referenced by
                // anything, so every payload file for it — not just the
                // sidecar — is safe to reclaim immediately rather than
                // waiting for a future restart's orphan sweep.
                try? fileManager.removeItem(at: url)
                cleanupSupersededPayloads(forKeyHash: hash, keeping: nil)
                continue
            }
            guard metadata.schemaVersion == AssetCacheMetadata.currentSchemaVersion,
                  metadata.cacheKeyHex == hash,
                  Self.isValidContentHash(metadata.payloadSHA256Hex)
            else {
                try? fileManager.removeItem(at: url)
                cleanupSupersededPayloads(forKeyHash: hash, keeping: nil)
                continue
            }
            let payloadURL = Self.payloadURL(
                in: directory,
                keyHash: hash,
                contentHash: metadata.payloadSHA256Hex
            )
            // Measure the payload the same untrusting way `get(_:)` does:
            // via filesystem attributes, never `metadata.encodedByteCount`.
            // A missing payload file, or one whose actual size is negative
            // or exceeds the configured cap, means this entry cannot be
            // trusted for accounting purposes either — quarantine it
            // rather than let it silently under- or over-count.
            guard
                let attributes = try? fileManager.attributesOfItem(atPath: payloadURL.path),
                let actualPayloadSize = attributes[.size] as? Int,
                actualPayloadSize >= 0, actualPayloadSize <= limits.maxEncodedBytes
            else {
                try? fileManager.removeItem(at: payloadURL)
                try? fileManager.removeItem(at: url)
                continue
            }
            result.append(
                Entry(
                    hash: hash,
                    metadata: metadata,
                    metadataBytes: data.count,
                    payloadBytes: actualPayloadSize
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

    func evictIfNeeded() {
        var current = entries()
        var total = current.reduce(0) { $0 + Self.accountedBytes(for: $1) }
        guard total > limits.highWaterMarkDiskBytes else { return }
        current.sort { $0.metadata.lastAccessedAt < $1.metadata.lastAccessedAt }
        for entry in current {
            guard total > limits.lowWaterMarkDiskBytes else { break }
            try? fileManager.removeItem(at: Self.payloadURL(
                in: directory,
                keyHash: entry.hash,
                contentHash: entry.metadata.payloadSHA256Hex
            ))
            try? fileManager
                .removeItem(at: directory.appendingPathComponent("\(entry.hash).meta.json"))
            total -= Self.accountedBytes(for: entry)
        }
    }
}
