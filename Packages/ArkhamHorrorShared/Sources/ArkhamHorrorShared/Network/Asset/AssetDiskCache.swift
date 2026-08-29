import Foundation

/// An actor-isolated on-disk cache bounded by
/// ``AssetCacheLimits/diskBudgetBytes``, storing each entry as an immutable,
/// content-addressed payload file plus a versioned JSON metadata sidecar
/// (the sole mutable "pointer" for that key) in the platform caches
/// directory.
///
/// A replacement is never published by overwriting an existing payload file
/// in place: the new payload is written under its own filename (derived
/// from ``AssetCacheMetadata/payloadSHA256Hex``, never from the request
/// path), so it can never collide with — or destroy — the file a prior
/// generation's metadata still references. Only after that write succeeds
/// does the metadata sidecar's own atomic (temp file + rename) write
/// "commit" the new generation; if that commit fails, the previous
/// metadata (still pointing at its own untouched payload file) remains
/// completely valid, so a mid-replacement failure can never leave a mixed
/// pair or destroy the prior good generation. Only once the pointer commit
/// has succeeded is any now-superseded payload file for that key removed.
///
/// Metadata, not filesystem `atime`, is authoritative for LRU. Corrupt
/// entries (hash/size mismatch, undecodable or version-mismatched
/// metadata, or a `payloadSHA256Hex` that is not exactly 64 lowercase hex
/// characters — never trusted to build a filesystem path unvalidated,
/// since it is untrusted on-disk input) are quarantined (deleted) on read
/// rather than surfaced as valid data. Orphaned payload files not
/// referenced by any currently valid metadata sidecar (including
/// superseded generations left behind by a crash between a payload write
/// and its metadata pointer commit), metadata sidecars with no payload at
/// all, and any leftover `.tmp` file from an interrupted write, are
/// recovered (deleted) once at startup.
actor AssetDiskCache {
    let directory: URL
    let limits: AssetCacheLimits
    let fileManager: FileManager
    var didRecoverOrphans = false

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
        let metadataURL = metadataURL(for: key)

        // A clean miss (no sidecar at all) is the common case for a
        // first-time lookup and must stay cheap: only fall through to the
        // quarantine path — which sweeps every payload generation for this
        // key hash via a full directory listing — once a sidecar is known
        // to exist but is unreadable or fails to decode.
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        guard let metadataData = try? Data(contentsOf: metadataURL),
              var metadata = try? JSONDecoder.assetCache.decode(
                  AssetCacheMetadata.self,
                  from: metadataData
              )
        else {
            quarantine(keyHash: key.digestHex, metadataURL: metadataURL)
            return nil
        }
        guard metadata.schemaVersion == AssetCacheMetadata.currentSchemaVersion,
              metadata.cacheKeyHex == key.digestHex,
              Self.isValidContentHash(metadata.payloadSHA256Hex)
        else {
            quarantine(keyHash: key.digestHex, metadataURL: metadataURL)
            return nil
        }
        // Only derived from a hash this method has just validated is
        // exactly 64 lowercase hex characters, so untrusted on-disk
        // metadata can never steer this path outside `directory`.
        let payloadURL = payloadURL(for: key, contentHash: metadata.payloadSHA256Hex)
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
            quarantine(keyHash: key.digestHex, metadataURL: metadataURL)
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
            quarantine(keyHash: key.digestHex, metadataURL: metadataURL)
            return nil
        }
        guard let payload = try? Data(contentsOf: payloadURL),
              payload.count == metadata.encodedByteCount
        else {
            quarantine(keyHash: key.digestHex, metadataURL: metadataURL)
            return nil
        }
        guard AssetPayloadHasher.sha256Hex(payload) == metadata.payloadSHA256Hex else {
            quarantine(keyHash: key.digestHex, metadataURL: metadataURL)
            return nil
        }

        metadata.lastAccessedAt = Date()
        try? persistMetadata(metadata, to: metadataURL)
        return CachedAsset(payload: payload, metadata: metadata)
    }

    /// Publishes `payload` under `metadata`'s key as a new, immutable,
    /// content-addressed generation, then atomically commits the metadata
    /// "pointer" to it, per the crash-consistency contract documented on
    /// this type.
    ///
    /// Rejects a `metadata.payloadSHA256Hex` that is not exactly 64
    /// lowercase hex characters before it is ever used to build a
    /// filesystem path — this value is normally computed by
    /// ``AssetPayloadHasher`` from `payload` itself, but this method must
    /// not assume that; validating its shape here is what keeps a future
    /// caller (or a value that started life as untrusted input) from
    /// steering a path outside `directory`.
    func set(_ key: AssetCacheKey, payload: Data, metadata: AssetCacheMetadata) throws {
        recoverOrphansIfNeeded()
        guard Self.isValidContentHash(metadata.payloadSHA256Hex) else {
            throw AssetError.cachePersistenceFailed("payloadSHA256Hex is not a valid content hash")
        }
        let newPayloadURL = payloadURL(for: key, contentHash: metadata.payloadSHA256Hex)
        // Content-addressed payloads are immutable *by contract*, but a
        // pre-existing file at this exact name is not automatically
        // trustworthy just because its name matches: it could have been
        // corrupted on disk, or (in principle) tampered with, while still
        // keeping the filename this call is about to publish under. So
        // the write always happens — `atomicWrite` already replaces an
        // existing file safely — re-asserting the known-good bytes rather
        // than silently trusting whatever is already there. Only whether
        // the file existed *before* this call is recorded, and purely to
        // decide whether a later metadata-commit failure may roll it
        // back: a payload this call did not originally create might still
        // be the one a surviving, untouched prior metadata sidecar
        // depends on, so it must never be deleted on rollback even though
        // its bytes were just (re)written.
        let payloadAlreadyExisted = fileManager.fileExists(atPath: newPayloadURL.path)
        do {
            try atomicWrite(payload, to: newPayloadURL)
        } catch {
            throw AssetError.cachePersistenceFailed(String(describing: error))
        }
        // The metadata sidecar is the single atomic "pointer" for this
        // key. If this write fails, any previous metadata — still
        // pointing at its own, untouched, differently-named payload file —
        // remains fully valid; the prior generation is never destroyed by
        // a failure here. If this call itself just created `newPayloadURL`
        // (rather than reusing a previously-persisted, still-referenced
        // generation), that now-unreferenced file is rolled back so a
        // failed publish never leaves an orphan behind; a payload this
        // call did not create is left untouched, since it may still be
        // the one a surviving, untouched prior metadata sidecar depends
        // on.
        do {
            try persistMetadata(metadata, to: metadataURL(for: key))
        } catch {
            if !payloadAlreadyExisted {
                try? fileManager.removeItem(at: newPayloadURL)
            }
            throw AssetError.cachePersistenceFailed(String(describing: error))
        }
        // Only now that the new generation is durably referenced is any
        // other, now-superseded payload file for this key removed —
        // including one left behind by an earlier crash between a prior
        // payload write and its own metadata pointer commit.
        cleanupSupersededPayloads(forKeyHash: key.digestHex, keeping: metadata.payloadSHA256Hex)
        evictIfNeeded()
    }

    /// Updates only the metadata sidecar for an already-cached `key` (for
    /// example bumping `lastAccessedAt` after a 304 revalidation), without
    /// re-writing the (unchanged) payload file. Throws if no payload
    /// currently exists on disk matching `metadata.payloadSHA256Hex`, so
    /// this can never create an orphaned metadata-only entry, nor point a
    /// committed metadata sidecar at a payload file that does not exist.
    func touch(_ key: AssetCacheKey, metadata: AssetCacheMetadata) throws {
        recoverOrphansIfNeeded()
        guard Self.isValidContentHash(metadata.payloadSHA256Hex) else {
            throw AssetError.cachePersistenceFailed("payloadSHA256Hex is not a valid content hash")
        }
        let payloadURL = payloadURL(for: key, contentHash: metadata.payloadSHA256Hex)
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
        // Removes every payload generation for this key (normally just
        // one), not only the one the current metadata references, so a
        // caller-initiated removal can never leave a superseded
        // generation behind.
        cleanupSupersededPayloads(forKeyHash: key.digestHex, keeping: nil)
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

    /// The filename for `key`'s payload under `contentHash` — the caller
    /// must have already validated `contentHash` via
    /// ``isValidContentHash(_:)`` if it did not originate from a value
    /// this cache computed itself (e.g. it was read back from an on-disk
    /// metadata sidecar).
    private func payloadURL(for key: AssetCacheKey, contentHash: String) -> URL {
        Self.payloadURL(in: directory, keyHash: key.digestHex, contentHash: contentHash)
    }

    static func payloadURL(in directory: URL, keyHash: String, contentHash: String) -> URL {
        directory.appendingPathComponent("\(keyHash).\(contentHash).bin")
    }

    private func metadataURL(for key: AssetCacheKey) -> URL {
        directory.appendingPathComponent("\(key.digestHex).meta.json")
    }

    /// Removes an entry that has failed integrity validation on read: its
    /// metadata sidecar, and — via
    /// ``cleanupSupersededPayloads(forKeyHash:keeping:)`` — every `.bin`
    /// payload generation on disk for `keyHash`, not merely whichever one
    /// generation the now-quarantined metadata happened to reference. This
    /// key hash's metadata is being deleted here, so no generation for it
    /// is left referenced by anything: any other stale generation (e.g.
    /// left behind by a crash between an earlier payload write and its own
    /// metadata commit) must be swept in the same pass rather than left to
    /// occupy disk space, uncounted against `diskBudgetBytes`, until a
    /// future process restart's orphan sweep happens to run.
    private func quarantine(keyHash: String, metadataURL: URL) {
        try? fileManager.removeItem(at: metadataURL)
        cleanupSupersededPayloads(forKeyHash: keyHash, keeping: nil)
    }

    /// `true` only for a string that is exactly 64 lowercase ASCII hex
    /// characters — the shape of a real SHA-256 hex digest, and the only
    /// shape ever safe to interpolate into a filesystem path derived from
    /// otherwise-untrusted on-disk metadata. In particular this rejects
    /// `/`, `..`, and any other path-traversal or delimiter-injection
    /// attempt a tampered metadata sidecar's `payloadSHA256Hex` field could
    /// otherwise smuggle into ``payloadURL(for:contentHash:)``.
    static func isValidContentHash(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
        }
    }

    // MARK: - Atomic persistence

    private func atomicWrite(_ data: Data, to finalURL: URL) throws {
        let tempURL = finalURL.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: tempURL)
        do {
            // Routed through `fileManager` (rather than `data.write(to:)`
            // directly) so an injected/real failure of the initial
            // temp-file write itself — not just the subsequent
            // rename/replace step — is exercised by the same cleanup path
            // below, and so tests can target this exact step the same way
            // they already target `moveItem`/`replaceItemAt`.
            guard fileManager.createFile(atPath: tempURL.path, contents: data) else {
                throw NSError(domain: "AssetDiskCache", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to write temp file at \(tempURL.path)",
                ])
            }
            if fileManager.fileExists(atPath: finalURL.path) {
                _ = try fileManager.replaceItemAt(finalURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: finalURL)
            }
        } catch {
            // Either the initial temp-file write (e.g. out-of-space or I/O
            // error) or the rename/replace step can fail after `tempURL`
            // already (partially or fully) exists on disk. Without this
            // cleanup, a failure here would leave `tempURL` behind for the
            // rest of this cache instance's lifetime: `recoverOrphansIfNeeded()`
            // only sweeps `.tmp` files once, on its very first call, so a
            // temp file created by a *later* failed write would otherwise
            // never be removed until the process restarts.
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    private func persistMetadata(_ metadata: AssetCacheMetadata, to url: URL) throws {
        let data = try JSONEncoder.assetCache.encode(metadata)
        try atomicWrite(data, to: url)
    }
}

/// Not `private`: `AssetDiskCache+Recovery.swift` also decodes metadata
/// sidecars with this exact decoder during startup recovery.
extension JSONEncoder {
    static let assetCache: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let assetCache: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
