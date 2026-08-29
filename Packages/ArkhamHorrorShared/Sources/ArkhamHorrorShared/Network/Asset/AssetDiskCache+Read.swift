import Foundation

/// The read/validate/quarantine path for ``AssetDiskCache``, split out
/// purely to keep the main file within this package's file-length
/// convention. See `AssetDiskCache.swift`'s type-level doc comment for
/// the full crash-consistency and quarantine contract this implements.
extension AssetDiskCache {
    /// Reads and validates the entry for `key`, recovering orphan/temp
    /// files from a prior run on first access. Returns `nil` on a clean
    /// miss; corrupt entries are quarantined (best-effort deleted) and
    /// also reported as a miss rather than thrown, since the caller's
    /// correct response to "there is no valid cached copy" is identical
    /// either way. A deletion failure while quarantining is intentionally
    /// not surfaced here — the caller cannot act on it differently than an
    /// ordinary miss for a *read*; it is ``remove(_:)``,
    /// ``AssetDiskCache/Recovery``, and eviction that need a typed
    /// deletion failure, since those are the paths where the caller must
    /// track a tombstone.
    func get(_ key: AssetCacheKey) -> CachedAsset? {
        recoverOrphansIfNeeded()
        let metadataName = metadataFilename(for: key)
        guard var metadata = readValidatedMetadata(for: key, metadataName: metadataName) else {
            return nil
        }
        guard let payload = readValidatedPayload(for: key, metadata: metadata) else {
            return nil
        }

        metadata.accessSequence = accessSequenceAllocator.allocate()
        try? persistMetadata(metadata, name: metadataName)
        return CachedAsset(payload: payload, metadata: metadata)
    }

    /// Reads, decodes, and validates the metadata sidecar for `key`,
    /// quarantining it (and returning `nil`) on any decode or consistency
    /// failure. Factored out of ``get(_:)`` purely to keep that function's
    /// own body within this package's length convention.
    private func readValidatedMetadata(
        for key: AssetCacheKey,
        metadataName: String
    ) -> AssetCacheMetadata? {
        // Both a genuine "does not exist" miss and any other read failure
        // (permission error, unexpected type, oversized sidecar) degrade
        // identically to a miss here: without a successfully read sidecar
        // there is nothing this call could safely quarantine by name
        // alone, and the caller's correct response ("there is no valid
        // cached copy") is the same either way.
        guard let metadataData = try? secureDirectory.read(
            name: metadataName,
            maxBytes: SecureCacheDirectory.maxMetadataBytes
        ) else {
            return nil
        }
        guard let metadata = try? JSONDecoder.assetCache().decode(
            AssetCacheMetadata.self,
            from: metadataData
        ) else {
            quarantine(keyHash: key.digestHex, metadataName: metadataName)
            return nil
        }
        guard metadata.schemaVersion == AssetCacheMetadata.currentSchemaVersion,
              metadata.cacheKeyHex == key.digestHex,
              Self.isValidContentHash(metadata.payloadSHA256Hex)
        else {
            quarantine(keyHash: key.digestHex, metadataName: metadataName)
            return nil
        }
        return metadata
    }

    /// Reads and validates the payload file `metadata` claims, cross-
    /// checking its declared size/hash against the real on-disk file
    /// before ever trusting it, quarantining (and returning `nil`) on any
    /// mismatch. Factored out of ``get(_:)`` purely to keep that
    /// function's own body within this package's length convention.
    private func readValidatedPayload(
        for key: AssetCacheKey,
        metadata: AssetCacheMetadata
    ) -> Data? {
        let metadataName = metadataFilename(for: key)
        // Only derived from a hash the caller has already validated is
        // exactly 64 lowercase hex characters, so untrusted on-disk
        // metadata can never steer this path outside the verified cache
        // directory.
        let payloadName = payloadFilename(
            keyHash: key.digestHex,
            contentHash: metadata.payloadSHA256Hex
        )
        // Validate the claimed size against the configured cap *before*
        // reading the payload into memory, and cross-check it against the
        // real on-disk file size (via a symlink-safe `fstatat`, never by
        // reading the file) before ever allocating for the read below.
        guard metadata.encodedByteCount >= 0, metadata.encodedByteCount <= limits.maxEncodedBytes
        else {
            quarantine(keyHash: key.digestHex, metadataName: metadataName)
            return nil
        }
        guard
            let attributes = try? secureDirectory.attributes(name: payloadName),
            attributes.isRegularFile,
            attributes.size == metadata.encodedByteCount,
            attributes.size <= limits.maxEncodedBytes
        else {
            quarantine(keyHash: key.digestHex, metadataName: metadataName)
            return nil
        }
        guard let payload = try? secureDirectory.read(
            name: payloadName,
            maxBytes: limits.maxEncodedBytes
        ),
            payload.count == metadata.encodedByteCount
        else {
            quarantine(keyHash: key.digestHex, metadataName: metadataName)
            return nil
        }
        guard AssetPayloadHasher.sha256Hex(payload) == metadata.payloadSHA256Hex else {
            quarantine(keyHash: key.digestHex, metadataName: metadataName)
            return nil
        }
        return payload
    }
}
