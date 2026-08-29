import Foundation

/// An actor-isolated on-disk cache bounded by
/// ``AssetCacheLimits/diskBudgetBytes``, storing each entry as a payload
/// file plus a versioned JSON metadata sidecar in the platform caches
/// directory.
///
/// Every write is atomic (temp file + rename) and metadata, not filesystem
/// `atime`, is authoritative for LRU. Corrupt entries (hash/size mismatch,
/// undecodable or version-mismatched metadata) are quarantined (deleted) on
/// read rather than surfaced as valid data. Orphaned payload-without-
/// metadata or metadata-without-payload files, and any leftover `.tmp` file
/// from an interrupted write, are recovered (deleted) once at startup.
actor AssetDiskCache {
    private let directory: URL
    private let limits: AssetCacheLimits
    private let fileManager: FileManager
    private var didRecoverOrphans = false

    init(directory: URL, limits: AssetCacheLimits, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.limits = limits
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The default production cache directory: a versioned subdirectory of
    /// the platform caches directory, so a future breaking layout change
    /// can ship as a new version directory without needing bespoke
    /// migration of the old one (out of scope per the issue's non-scope
    /// list; the old directory is simply abandoned and reclaimed by the OS
    /// or manual cleanup).
    static func productionDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw AssetError.cachePersistenceFailed("No caches directory available")
        }
        return base.appendingPathComponent("ArkhamHorrorAssets", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    /// Reads and validates the entry for `key`, recovering orphan/temp
    /// files from a prior run on first access. Returns `nil` on a clean
    /// miss; corrupt entries are quarantined (deleted) and also reported as
    /// a miss rather than thrown, since the caller's correct response to
    /// "there is no valid cached copy" is identical either way.
    func get(_ key: AssetCacheKey) -> CachedAsset? {
        recoverOrphansIfNeeded()
        let payloadURL = payloadURL(for: key)
        let metadataURL = metadataURL(for: key)

        guard let metadataData = try? Data(contentsOf: metadataURL),
              var metadata = try? JSONDecoder.assetCache.decode(
                  AssetCacheMetadata.self,
                  from: metadataData
              )
        else {
            quarantine(payloadURL: payloadURL, metadataURL: metadataURL)
            return nil
        }
        guard metadata.schemaVersion == AssetCacheMetadata.currentSchemaVersion,
              metadata.cacheKeyHex == key.digestHex
        else {
            quarantine(payloadURL: payloadURL, metadataURL: metadataURL)
            return nil
        }
        // Validate the claimed size against the configured cap *before*
        // reading the payload into memory. Metadata is untrusted input
        // (it could be corrupted or tampered while still round-tripping
        // through JSON decoding): without this guard, a claimed
        // `encodedByteCount` that is negative or absurdly large could
        // force an oversized `Data(contentsOf:)` allocation, or mask a
        // read of a payload file that was substituted after the fact,
        // before the byte-count mismatch check below ever runs.
        guard metadata.encodedByteCount >= 0, metadata.encodedByteCount <= limits.maxEncodedBytes
        else {
            quarantine(payloadURL: payloadURL, metadataURL: metadataURL)
            return nil
        }
        // Also check the actual on-disk file size via filesystem
        // attributes (not by reading it) before the read below: if the
        // payload file itself was substituted for something larger than
        // whatever size metadata claims, the file-size check catches that
        // without ever allocating for the oversized read.
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: payloadURL.path),
            let actualSize = attributes[.size] as? Int,
            actualSize >= 0, actualSize <= limits.maxEncodedBytes
        else {
            quarantine(payloadURL: payloadURL, metadataURL: metadataURL)
            return nil
        }
        guard let payload = try? Data(contentsOf: payloadURL),
              payload.count == metadata.encodedByteCount
        else {
            quarantine(payloadURL: payloadURL, metadataURL: metadataURL)
            return nil
        }
        guard AssetPayloadHasher.sha256Hex(payload) == metadata.payloadSHA256Hex else {
            quarantine(payloadURL: payloadURL, metadataURL: metadataURL)
            return nil
        }

        metadata.lastAccessedAt = Date()
        try? persistMetadata(metadata, to: metadataURL)
        return CachedAsset(payload: payload, metadata: metadata)
    }

    /// Persists `payload` and `metadata` atomically. If the metadata write
    /// fails after the payload write succeeded, the payload is removed
    /// before rethrowing so no orphaned, half-written entry is left looking
    /// like it might be valid.
    func set(_ key: AssetCacheKey, payload: Data, metadata: AssetCacheMetadata) throws {
        recoverOrphansIfNeeded()
        let payloadURL = payloadURL(for: key)
        let metadataURL = metadataURL(for: key)
        do {
            try atomicWrite(payload, to: payloadURL)
        } catch {
            throw AssetError.cachePersistenceFailed(String(describing: error))
        }
        do {
            try persistMetadata(metadata, to: metadataURL)
        } catch {
            try? fileManager.removeItem(at: payloadURL)
            throw AssetError.cachePersistenceFailed(String(describing: error))
        }
        evictIfNeeded()
    }

    /// Updates only the metadata sidecar for an already-cached `key` (for
    /// example bumping `lastAccessedAt` after a 304 revalidation), without
    /// re-writing the (unchanged) payload file. Throws if no payload
    /// currently exists on disk for `key`, so this can never create an
    /// orphaned metadata-only entry.
    func touch(_ key: AssetCacheKey, metadata: AssetCacheMetadata) throws {
        recoverOrphansIfNeeded()
        let payloadURL = payloadURL(for: key)
        guard fileManager.fileExists(atPath: payloadURL.path) else {
            throw AssetError.cachePersistenceFailed("No cached payload to touch for this key")
        }
        do {
            try persistMetadata(metadata, to: metadataURL(for: key))
        } catch {
            throw AssetError.cachePersistenceFailed(String(describing: error))
        }
    }

    func remove(_ key: AssetCacheKey) {
        try? fileManager.removeItem(at: payloadURL(for: key))
        try? fileManager.removeItem(at: metadataURL(for: key))
    }

    func removeAll() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Total accounted bytes (payload + exact on-disk metadata size) across
    /// every currently valid entry. Used only by tests to assert exact
    /// quota accounting; production eviction re-derives this from disk
    /// directly so it never drifts from what is actually persisted.
    func totalAccountedBytes() -> Int {
        entries().reduce(0) { $0 + Self.accountedBytes(for: $1) }
    }

    // MARK: - Paths

    private func payloadURL(for key: AssetCacheKey) -> URL {
        directory.appendingPathComponent("\(key.digestHex).bin")
    }

    private func metadataURL(for key: AssetCacheKey) -> URL {
        directory.appendingPathComponent("\(key.digestHex).meta.json")
    }

    // MARK: - Atomic persistence

    private func atomicWrite(_ data: Data, to finalURL: URL) throws {
        let tempURL = finalURL.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: tempURL)
        try data.write(to: tempURL, options: [])
        if fileManager.fileExists(atPath: finalURL.path) {
            _ = try fileManager.replaceItemAt(finalURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: finalURL)
        }
    }

    private func persistMetadata(_ metadata: AssetCacheMetadata, to url: URL) throws {
        let data = try JSONEncoder.assetCache.encode(metadata)
        try atomicWrite(data, to: url)
    }

    // MARK: - Corruption / orphan recovery

    private func quarantine(payloadURL: URL, metadataURL: URL) {
        try? fileManager.removeItem(at: payloadURL)
        try? fileManager.removeItem(at: metadataURL)
    }

    /// Runs once per cache instance lifetime (covering the common "cache
    /// created once at app launch" case, which is what makes this a real
    /// restart-recovery pass rather than a per-call cost). Removes any
    /// leftover `.tmp` file from an interrupted write, any payload with no
    /// matching metadata sidecar, and any metadata sidecar with no matching
    /// payload.
    private func recoverOrphansIfNeeded() {
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

        var payloadHashes: Set<String> = []
        var metadataHashes: Set<String> = []
        for url in contents {
            let name = url.lastPathComponent
            if name.hasSuffix(".tmp") {
                try? fileManager.removeItem(at: url)
            } else if name.hasSuffix(".bin") {
                payloadHashes.insert(String(name.dropLast(".bin".count)))
            } else if name.hasSuffix(".meta.json") {
                metadataHashes.insert(String(name.dropLast(".meta.json".count)))
            }
        }
        for hash in payloadHashes.subtracting(metadataHashes) {
            try? fileManager.removeItem(at: directory.appendingPathComponent("\(hash).bin"))
        }
        for hash in metadataHashes.subtracting(payloadHashes) {
            try? fileManager.removeItem(at: directory.appendingPathComponent("\(hash).meta.json"))
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
    private struct Entry {
        let hash: String
        let metadata: AssetCacheMetadata
        let metadataBytes: Int
        let payloadBytes: Int
    }

    private func entries() -> [Entry] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        else { return [] }
        var result: [Entry] = []
        for url in contents where url.lastPathComponent.hasSuffix(".meta.json") {
            let hash = String(url.lastPathComponent.dropLast(".meta.json".count))
            let payloadURL = directory.appendingPathComponent("\(hash).bin")
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
                // looked up again via `get(_:)`.
                quarantine(payloadURL: payloadURL, metadataURL: url)
                continue
            }
            guard metadata.schemaVersion == AssetCacheMetadata.currentSchemaVersion,
                  metadata.cacheKeyHex == hash
            else {
                quarantine(payloadURL: payloadURL, metadataURL: url)
                continue
            }
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
                quarantine(payloadURL: payloadURL, metadataURL: url)
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
    private static func accountedBytes(for entry: Entry) -> Int {
        entry.payloadBytes + entry.metadataBytes
    }

    private func evictIfNeeded() {
        var current = entries()
        var total = current.reduce(0) { $0 + Self.accountedBytes(for: $1) }
        guard total > limits.highWaterMarkDiskBytes else { return }
        current.sort { $0.metadata.lastAccessedAt < $1.metadata.lastAccessedAt }
        for entry in current {
            guard total > limits.lowWaterMarkDiskBytes else { break }
            try? fileManager.removeItem(at: directory.appendingPathComponent("\(entry.hash).bin"))
            try? fileManager
                .removeItem(at: directory.appendingPathComponent("\(entry.hash).meta.json"))
            total -= Self.accountedBytes(for: entry)
        }
    }
}

private extension JSONEncoder {
    static let assetCache: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let assetCache: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
