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
    ///
    /// A `CancellationError` from acquiring the cross-process lock is
    /// rethrown rather than folded into a plain `nil` miss: a caller whose
    /// task was cancelled while merely *waiting* for this lock has learned
    /// nothing about whether the entry exists, and treating that as a
    /// miss would incorrectly send ``AssetCacheService`` on to a fresh
    /// (and pointless, since nobody is still listening) network fetch
    /// instead of letting the cancellation propagate -- exactly the same
    /// contract
    /// ``AssetCacheService/revalidateDiskHit(_:key:cacheKey:candidates:token:)``
    /// already upholds for cancellation encountered *after* a disk hit.
    /// Every other lock-acquisition failure (a genuine I/O error, a
    /// tampered lock file, and so on) still reports as an ordinary miss,
    /// exactly as before.
    func get(_ key: AssetCacheKey) async throws -> CachedAsset? {
        // Same single-top-level-lock convention as
        // ``set(_:payload:metadata:token:)``/``touch(_:metadata:token:)``/
        // ``remove(_:token:)``: a read that examined this key's metadata
        // and payload without holding this cache's cross-process lock
        // could observe an inconsistent pair mid-write by a concurrent
        // writer (this or another process) — for example a freshly
        // committed metadata pointer paired with a payload generation
        // whose own write has not yet reached disk, or a payload file a
        // concurrent cleanup pass deletes between this read validating
        // the metadata and opening the payload — and then wrongly
        // *quarantine* (delete) that other writer's perfectly valid,
        // just-published entry purely because of the interleaving, not
        // because anything was actually wrong with it. The lock is
        // released again before the test-only pause/return below: the
        // race that pause exists to reproduce is at the
        // ``AssetCacheService`` token-authority layer (a purely in-memory,
        // per-process concern already handled by
        // ``AssetCacheService/unchanged(since:for:)``), not a disk-file-
        // consistency concern this lock protects, so holding it any
        // longer than the actual file I/O below would serve no purpose.
        let lockFD: Int32
        do {
            lockFD = try await secureDirectory.acquireExclusiveLock()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        let result = getLocked(key)
        secureDirectory.releaseExclusiveLock(lockFD)
        if let pause = testOnlyPauseBeforeReturningHit {
            await pause()
        }
        return result
    }

    private func getLocked(_ key: AssetCacheKey) -> CachedAsset? {
        recoverOrphansIfNeeded()
        let metadataName = metadataFilename(for: key)
        guard var metadata = readValidatedMetadata(for: key, metadataName: metadataName) else {
            return nil
        }
        guard let payload = readValidatedPayload(for: key, metadata: metadata) else {
            return nil
        }
        // Cross-checks this entry's own durable applied *disposition*
        // (`AssetDiskCache+Disposition.swift`) before ever trusting a
        // structurally-valid-looking metadata+payload pair: a metadata
        // sidecar can still be physically present and perfectly
        // well-formed even after this exact key's disposition has since
        // durably advanced to `.retiring`/`.tombstone` (a definitive 404,
        // or a cancellation-triggered retraction, whose own destructive
        // deletion step failed or has simply not yet run — physical
        // cleanup is deliberately best-effort once the disposition itself
        // is durable; see ``commitRetractionLocked(for:token:destroy:)``'s
        // own doc comment), or even after a *different*, newer authority's
        // own publication has since landed for this exact key. Without
        // this check, any reader that races ahead of best-effort physical
        // cleanup — a fresh service instance, an independent sibling
        // process, or this same process after a restart, not merely the
        // process whose in-memory authority already knows to distrust
        // this entry — could still serve content that has since been
        // durably confirmed gone. A mismatch quarantines the stale
        // sidecar/payload pair here (self-healing the very inconsistency
        // this check exists to catch) and reports an ordinary miss.
        guard
            let disposition = try? currentDispositionLocked(for: key),
            disposition.kind == .content,
            disposition.authorityID == metadata.authorityIDAtPublication,
            disposition.contentHash == metadata.payloadSHA256Hex
        else {
            quarantine(keyHash: key.digestHex, metadataName: metadataName)
            return nil
        }

        // Bumped to the next durable, globally monotonic value via
        // ``SecureCacheDirectory/allocateAccessSequence(atLeastAfter:)``,
        // seeded with whatever value this exact entry was already last
        // persisted with (the freshest on-disk truth available, obtained
        // under the same exclusive lock this whole read holds) purely as
        // an extra floor for a freshly created cache root whose durable
        // counter file does not exist yet — see that type's own doc
        // comment for why a purely local, per-actor-instance counter is
        // not sufficient to prevent two different actor instances from
        // assigning colliding or out-of-order sequences to two different
        // keys. A failure to durably persist the bumped value here is
        // best-effort only (this is an LRU-touch refresh, not a
        // correctness precondition for the read itself): the entry's own
        // previously-persisted sequence is kept unchanged rather than
        // failing the whole read.
        if let allocated = try? secureDirectory.allocateAccessSequence(
            atLeastAfter: metadata.accessSequence
        ) {
            metadata.accessSequence = allocated
        }
        try? persistMetadata(metadata, name: metadataName)
        // Reconstructs this entry's own historical publication authority
        // directly from `metadata` -- read together with `payload` under
        // this exact locked call, never re-derived from whatever epoch/
        // identifier happens to be current *now* -- so a revalidation of this
        // exact hit can thread this entry's own historical stamp through
        // as its operation's token authority, rather than a freshly
        // re-read "current" one. See
        // ``AssetCacheMetadata/clearEpochAtPublication``'s doc comment.
        return CachedAsset(
            payload: payload,
            metadata: metadata,
            durableClearEpoch: metadata.clearEpochAtPublication,
            authorityID: metadata.authorityIDAtPublication
        )
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
