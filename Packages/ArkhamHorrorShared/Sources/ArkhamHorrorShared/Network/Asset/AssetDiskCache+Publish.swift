import Foundation

private extension AssetDiskCache {
    /// Preserves an already-typed ``AssetError`` as-is (so a caller sees
    /// the real underlying failure, e.g. a corrupt-entry or configuration
    /// error surfaced by `SecureCacheDirectory`) and only wraps a foreign
    /// error type in ``AssetError/cachePersistenceFailed(_:)``. Wrapping
    /// unconditionally would re-wrap an already-`.cachePersistenceFailed`
    /// error inside another one, producing a nested, less useful
    /// diagnostic string (`cachePersistenceFailed("cachePersistenceFailed(...)")`)
    /// and discarding whichever more specific `AssetError` case the
    /// original failure actually was.
    static func asCachePersistenceFailure(_ error: Error) -> AssetError {
        if let assetError = error as? AssetError {
            return assetError
        }
        return .cachePersistenceFailed(String(describing: error))
    }
}

/// The crash-durable two-phase payload-write and metadata-pointer-commit
/// steps behind ``AssetDiskCache/setLocked(_:payload:metadata:token:)``.
/// Split out of the main actor file purely to stay under this package's
/// file-length limit; every member here is still actor-isolated
/// `AssetDiskCache` state/behavior.
extension AssetDiskCache {
    /// Step 1 of ``setLocked(_:payload:metadata:token:)``: writes the
    /// payload generation's bounded temp file, fsyncs it, then
    /// renames+fsyncs-directory to publish it under its permanent,
    /// content-addressed name. A crash before this completes leaves only
    /// an orphan temp file, cleaned up by the next
    /// ``recoverOrphansIfNeeded()`` — the previous generation (if any) is
    /// entirely untouched. A failure caught *within this process* (rather
    /// than an actual crash) instead removes that leftover temp file
    /// immediately, rather than deferring its cleanup to a future
    /// restart's one-time orphan sweep. Factored out of `setLocked` purely
    /// to stay under this package's `function_body_length` convention.
    func writePayloadGenerationLocked(payloadName: String, payload: Data) throws {
        do {
            try secureDirectory.writeTempAndFsync(tempName: payloadName + ".tmp", data: payload)
            try secureDirectory.renameAndFsyncDirectory(from: payloadName + ".tmp", to: payloadName)
        } catch {
            _ = try? secureDirectory.remove(name: payloadName + ".tmp")
            throw Self.asCachePersistenceFailure(error)
        }
    }

    /// Steps 2 and 3 of ``setLocked(_:payload:metadata:token:)``: commits
    /// the metadata pointer, then — only once that commit is durably
    /// confirmed — removes any now-superseded prior payload generation and
    /// clears this key's durable tombstone (if any). The pointer rename
    /// and the subsequent directory `fsync` are deliberately two
    /// separately-throwing calls (not the composite
    /// ``SecureCacheDirectory/renameAndFsyncDirectory(from:to:)`` helper
    /// other call sites use), because this call site's failure handling
    /// *must* distinguish them: if the rename itself never took effect (or
    /// the write/encode before it failed), the previous metadata sidecar
    /// (still pointing at its own, untouched, differently-named payload
    /// file) remains fully valid, and the payload just written above --
    /// not yet referenced by anything -- is safe to roll back. But if the
    /// rename *succeeded* and only the following directory `fsync` failed,
    /// the metadata pointer has already, currently, actually been switched
    /// to reference the new payload -- in this running process,
    /// independent of any future crash -- so deleting that payload here
    /// (as an unconditional "the commit failed, undo it" rollback would)
    /// would immediately break a reference that is already live, not
    /// merely leave a future crash free to resurrect stale state. In that
    /// case this still throws (the caller must know durability was not
    /// confirmed), but never deletes the payload; at worst, a real crash
    /// before a later `fsync` reverts the rename at the filesystem level,
    /// which the next startup's orphan sweep already tolerates by design
    /// (the payload simply becomes an unreferenced orphan, never a
    /// dangling reference). Factored out of `setLocked` purely to stay
    /// under this package's `function_body_length` convention.
    func commitMetadataPointerLocked(
        _ key: AssetCacheKey,
        metadata: AssetCacheMetadata,
        payloadName: String,
        payloadAlreadyExisted: Bool
    ) throws {
        var stamped = metadata
        let metadataName = metadataFilename(for: key)
        // A best-effort read of whatever metadata sidecar currently
        // occupies this exact name (if any): seeds
        // ``AssetAccessSequenceAllocator/allocate(atLeastAfter:)`` so this
        // write can never stamp a *lower* sequence than a different actor
        // instance (another concurrent ``AssetDiskCache`` in this
        // process, or a genuinely separate process/instance) already
        // persisted for this exact key since this actor's own allocator
        // was last seeded — see ``getLocked(_:)``'s identical use of this
        // pattern for its LRU-touch path. Any failure to read/decode the
        // existing sidecar (including "does not exist yet") is treated
        // identically to "no prior value": this is a monotonicity
        // refinement, not a correctness precondition for the write itself.
        if let existing = existingAccessSequence(metadataName: metadataName) {
            stamped.accessSequence = accessSequenceAllocator.allocate(
                atLeastAfter: existing
            )
        } else {
            stamped.accessSequence = accessSequenceAllocator.allocate()
        }
        let metadataTempName = metadataName + ".tmp"
        do {
            let data = try JSONEncoder.assetCache().encode(stamped)
            try secureDirectory.writeTempAndFsync(tempName: metadataTempName, data: data)
            try secureDirectory.rename(from: metadataTempName, to: metadataName)
        } catch {
            _ = try? secureDirectory.remove(name: metadataTempName)
            if !payloadAlreadyExisted {
                _ = try? secureDirectory.remove(name: payloadName)
            }
            throw Self.asCachePersistenceFailure(error)
        }
        do {
            try secureDirectory.fsyncRootDirectory()
        } catch {
            throw AssetError.cachePersistenceFailed(
                "metadata pointer committed but its directory fsync failed: \(error)"
            )
        }

        // Only now that the new generation is durably referenced, remove
        // any other, now-superseded payload generation for this key —
        // including one left behind by an earlier crash between a prior
        // payload write and its own metadata pointer commit — then fsync
        // once more so that cleanup itself is durable. Also clears any
        // earlier durable tombstone for this exact key (see
        // ``persistTombstoneLocked(keyHash:)``): a fresh, verified
        // generation that just durably committed is itself the "durable
        // clear" a prior failed deletion was protecting against.
        cleanupSupersededPayloads(forKeyHash: key.digestHex, keeping: metadata.payloadSHA256Hex)
        clearTombstoneLocked(keyHash: key.digestHex)
        try? secureDirectory.fsyncRootDirectory()
    }

    /// Best-effort read of the `accessSequence` currently stamped on
    /// whatever metadata sidecar occupies `metadataName` right now, or
    /// `nil` if none exists or it cannot be read/decoded. Only ever used
    /// to seed ``AssetAccessSequenceAllocator/allocate(atLeastAfter:)``,
    /// never as a correctness precondition, so any failure here
    /// (including a genuine "does not exist yet" miss) is deliberately
    /// folded into a single `nil` case rather than surfaced.
    private func existingAccessSequence(metadataName: String) -> AssetAccessSequence? {
        guard let existingData = try? secureDirectory.read(
            name: metadataName,
            maxBytes: SecureCacheDirectory.maxMetadataBytes
        ) else {
            return nil
        }
        return try? JSONDecoder.assetCache().decode(
            AssetCacheMetadata.self,
            from: existingData
        ).accessSequence
    }
}
