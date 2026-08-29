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
    func get(_ key: AssetCacheKey) async -> CachedAsset? {
        recoverOrphansIfNeeded()
        // Fail-closed checks first, before any other work: a whole-cache
        // "disk reads disabled" marker (an unenumerable `removeAll()`
        // survivor listing previously left this cache unable to durably
        // tombstone specific keys) or this exact key's own durable
        // tombstone (a previously failed metadata-pointer deletion) both
        // mean "never serve this" regardless of what a purely structural
        // read of the metadata+payload pair would otherwise accept.
        guard !areDiskReadsDisabled(), !isTombstoned(keyHash: key.digestHex) else {
            return nil
        }
        let metadataName = metadataFilename(for: key)
        guard var metadata = readValidatedMetadata(for: key, metadataName: metadataName) else {
            return nil
        }
        guard let payload = readValidatedPayload(for: key, metadata: metadata) else {
            return nil
        }

        metadata.accessSequence = accessSequenceAllocator.allocate()
        try? persistMetadata(metadata, name: metadataName)
        // Test-only: lets a test deterministically interleave another
        // operation (e.g. `AssetCacheService.evictAll()`) between this
        // read having already validated a hit in-memory and this call
        // actually returning it to the caller — reproducing the exact
        // race `AssetCacheService.unchanged(since:for:)` exists to reject,
        // without depending on incidental actor-scheduling order. `nil` in
        // every production path and every test that does not explicitly
        // install it.
        if let pause = testOnlyPauseBeforeReturningHit {
            await pause()
        }
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
        // A genuine "does not exist" miss (``SecureCacheDirectory/read``
        // returns `nil`, never throws, for `ENOENT`) is not quarantined —
        // there is nothing occupying this name to clean up. Any *other*
        // failure — a thrown error for a symlink/non-regular entry, an
        // oversized sidecar, or a permission error — means something
        // invalid *does* occupy this exact, hash-derived name, and must be
        // quarantined here rather than silently degrading to a miss:
        // otherwise it can never be reclaimed (it is not valid JSON to
        // decode, so it would never reach either `quarantine` call below)
        // and every future lookup for this key repeats the same failed
        // read forever.
        let metadataData: Data?
        do {
            metadataData = try secureDirectory.read(
                name: metadataName,
                maxBytes: SecureCacheDirectory.maxMetadataBytes
            )
        } catch {
            quarantine(keyHash: key.digestHex, metadataName: metadataName)
            return nil
        }
        guard let metadataData else {
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
