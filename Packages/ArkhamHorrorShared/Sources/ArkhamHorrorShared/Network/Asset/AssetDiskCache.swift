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

    func remove(_ key: AssetCacheKey) {
        try? fileManager.removeItem(at: payloadURL(for: key))
        try? fileManager.removeItem(at: metadataURL(for: key))
    }

    func removeAll() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Total accounted bytes (payload + metadata overhead) across every
    /// currently valid entry. Used only by tests to assert exact quota
    /// accounting; production eviction re-derives this from disk directly
    /// so it never drifts from what is actually persisted.
    func totalAccountedBytes() -> Int {
        entries().reduce(0) { $0 + $1.metadata.accountedByteCount }
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
        didRecoverOrphans = true
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        else { return }

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

    private func entries() -> [(hash: String, metadata: AssetCacheMetadata)] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        else { return [] }
        var result: [(hash: String, metadata: AssetCacheMetadata)] = []
        for url in contents where url.lastPathComponent.hasSuffix(".meta.json") {
            let hash = String(url.lastPathComponent.dropLast(".meta.json".count))
            guard let data = try? Data(contentsOf: url),
                  let metadata = try? JSONDecoder.assetCache.decode(
                      AssetCacheMetadata.self,
                      from: data
                  )
            else { continue }
            result.append((hash, metadata))
        }
        return result
    }

    private func evictIfNeeded() {
        var current = entries()
        var total = current.reduce(0) { $0 + $1.metadata.accountedByteCount }
        guard total > limits.highWaterMarkDiskBytes else { return }
        current.sort { $0.metadata.lastAccessedAt < $1.metadata.lastAccessedAt }
        for entry in current {
            guard total > limits.lowWaterMarkDiskBytes else { break }
            try? fileManager.removeItem(at: directory.appendingPathComponent("\(entry.hash).bin"))
            try? fileManager
                .removeItem(at: directory.appendingPathComponent("\(entry.hash).meta.json"))
            total -= entry.metadata.accountedByteCount
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
