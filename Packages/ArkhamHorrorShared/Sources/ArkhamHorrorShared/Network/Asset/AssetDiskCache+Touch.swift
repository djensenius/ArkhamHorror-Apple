import Foundation

/// ``AssetDiskCache/touch(_:metadata:token:)``, split out of the main file
/// purely to stay under this package's `file_length` convention, exactly
/// like `AssetDiskCache+Recovery.swift`.
extension AssetDiskCache {
    /// Updates only the metadata sidecar for an already-cached `key` (for
    /// example bumping ``AssetCacheMetadata/accessSequence`` after a 304
    /// revalidation), without re-writing the unchanged payload file.
    /// Throws if no payload currently exists on disk matching
    /// `metadata.payloadSHA256Hex`, so this can never create an orphaned
    /// metadata-only entry. `token`, when supplied, gates this the same
    /// way as ``set(_:payload:metadata:token:)`` — including returning
    /// ``AssetCacheService/MutationOutcome/stale`` rather than a silent
    /// `Void` success on a CAS rejection.
    @discardableResult
    func touch(
        _ key: AssetCacheKey,
        metadata: AssetCacheMetadata,
        token: AssetCacheService.CacheToken? = nil
    ) async throws -> AssetCacheService.MutationOutcome {
        // Same single-top-level-lock convention as ``set(_:payload:metadata:token:)``.
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        return try touchLocked(key, metadata: metadata, token: token)
    }

    private func touchLocked(
        _ key: AssetCacheKey,
        metadata: AssetCacheMetadata,
        token: AssetCacheService.CacheToken?
    ) throws -> AssetCacheService.MutationOutcome {
        try ensureRootAuthorityInitializedLocked()
        let currentEpoch = try secureDirectory.readPersistedClearEpoch()
        let currentIssued = try currentIssuedTicketLocked(for: key)
        if let token {
            guard acceptToken(
                token,
                currentEpoch: currentEpoch,
                currentIssued: currentIssued
            ) else {
                return .stale
            }
        }
        // A mismatched `metadata.cacheKeyHex` here would persist a sidecar
        // that later reads as belonging to a *different* key than the one
        // actually touched: `AssetDiskCache+Read.swift` and
        // `AssetDiskCache+Recovery.swift` both treat `cacheKeyHex` as this
        // entry's own authoritative identity when validating/quarantining
        // survivors, so a caller-supplied mismatch here (accidental, or
        // from a future internal caller) could persist an entry that is
        // later quarantined and trigger unintended cleanup of payload
        // generations belonging to the real key. Fail fast rather than
        // ever persist that mismatch.
        guard metadata.cacheKeyHex == key.digestHex else {
            throw AssetError.cachePersistenceFailed(
                "metadata.cacheKeyHex does not match the AssetCacheKey being touched"
            )
        }
        guard Self.isValidContentHash(metadata.payloadSHA256Hex) else {
            throw AssetError.cachePersistenceFailed("payloadSHA256Hex is not a valid content hash")
        }
        let payloadName = payloadFilename(
            keyHash: key.digestHex,
            contentHash: metadata.payloadSHA256Hex
        )
        // A symlink or other non-regular entry at this name is never a
        // verified payload to touch: publishing a metadata sidecar that
        // points at it would let a later read quarantine the mismatch,
        // but only after having already accepted a bogus pointer as if it
        // were a legitimate revalidation. Require a verified regular file
        // before committing the metadata bump.
        //
        // Deliberately a distinct, typed case
        // (``AssetError/entryNoLongerCachedToTouch``) rather than the
        // generic ``AssetError/cachePersistenceFailed(_:)`` used
        // elsewhere in this method: a missing payload here is not a mere
        // I/O hiccup a caller may treat as best-effort/non-fatal — it is
        // definitive proof that some other, more-recently-concluded
        // operation for this exact key (a definitive 404 invalidation, a
        // fresh publish under new content whose own commit already
        // cleaned up this generation, or a whole-cache clear) already
        // removed this entry from the *shared* disk cache. A caller
        // (``AssetCacheService/touch(_:asset:token:)``) that already
        // wrote this same revalidation into its own *private* in-memory
        // cache under this same token must retract that write rather
        // than treat this as recoverable — otherwise memory alone could
        // go on serving stale bytes the shared disk has already disowned,
        // indefinitely, regardless of what any other cache instance
        // sharing this directory has since done.
        guard (try? secureDirectory.attributes(name: payloadName))?.isRegularFile == true else {
            throw AssetError.entryNoLongerCachedToTouch
        }
        var stamped = metadata
        // See ``SecureCacheDirectory/allocateAccessSequence(atLeastAfter:)``'s
        // doc comment: `metadata.accessSequence` here is this exact
        // entry's own previously-known value (as most recently observed
        // by whichever caller is now touching it), folded in purely as an
        // extra floor for a freshly created cache root whose durable
        // counter file does not exist yet — the counter file itself is
        // always authoritative once it exists.
        stamped.accessSequence = try secureDirectory.allocateAccessSequence(
            atLeastAfter: metadata.accessSequence
        )
        do {
            try persistMetadata(stamped, name: metadataFilename(for: key))
        } catch {
            throw AssetError.cachePersistenceFailed(String(describing: error))
        }
        // Same single-top-level-lock convention as ``set(_:payload:metadata:token:)``:
        // commits `token`'s own already-accepted ticket verbatim (never a
        // freshly-reserved one) when `token` is non-nil — see
        // ``commitMutationTicketLocked(for:token:)``'s own doc comment
        // for why conflating the two would break
        // ``removeIfApplied(_:token:)``'s exact-match retraction.
        try commitMutationTicketLocked(for: key, token: token)
        return .applied
    }
}
