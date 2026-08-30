import Foundation

/// Token compare-and-swap bookkeeping, content-hash validation, and
/// filename derivation for `AssetDiskCache`, split out of
/// `AssetDiskCache.swift` purely to stay under this package's
/// `file_length` convention.
extension AssetDiskCache {
    // MARK: - Token CAS

    /// Refuses to accept a new payload write while this cache's on-disk
    /// budget is not currently provably under control — see
    /// ``AssetDiskCache/Tombstone/markDiskWritesDisabledLocked()``'s doc
    /// comment for exactly what durably sets/clears that state. Attempts
    /// one fresh ``evictIfNeeded()`` recovery pass first: a marker left
    /// over from a now-resolved transient failure (a filesystem that was
    /// briefly full or read-only, for example) must not permanently block
    /// every future write once conditions have actually improved, but a
    /// marker that persists even after this fresh attempt means physical
    /// usage genuinely cannot be confirmed or brought under budget right
    /// now, and this call's own new payload must not be allowed to make
    /// that unknown/over-budget state larger still.
    func requireDiskWritesEnabledLocked() throws {
        guard areDiskWritesDisabledLocked() else { return }
        evictIfNeeded()
        guard !areDiskWritesDisabledLocked() else {
            throw AssetError.cachePersistenceFailed(
                "Disk writes are disabled: on-disk cache budget could not be confirmed"
            )
        }
    }

    /// The compare half of this actor's own token CAS: accepts `token`
    /// only if its generation is not older than the generation this actor
    /// currently accepts writes under, and it is strictly newer than
    /// whatever token this actor last recorded as applied for `key` (a
    /// `nil` prior value always accepts). Records `token` as the new
    /// applied value on acceptance so a subsequent, older-issued token for
    /// the same key can never later overwrite it. Mirrors
    /// ``AssetMemoryCache``'s identical private helper of the same name.
    /// Not `private`: also called from `AssetDiskCache+Removal.swift`'s
    /// `remove(_:token:)`/`removeAll()`, in the same file-length budget
    /// as this type.
    func acceptToken(
        _ token: AssetCacheService.CacheToken,
        for key: AssetCacheKey
    ) -> Bool {
        guard token.generation >= acceptedGeneration else { return false }
        if let applied = appliedToken[key], applied >= token {
            return false
        }
        appliedToken[key] = token
        return true
    }

    /// Removes `key`'s on-disk entry only if `token` is *exactly* the
    /// applied token currently recorded for it — mirrors
    /// ``AssetMemoryCache/removeIfApplied(_:token:)``'s exact-match
    /// semantics (as opposed to ``remove(_:token:)``'s "reject if a newer
    /// token already applied" compare-and-swap). Used by
    /// ``AssetCacheService/publish(_:asset:token:)``/
    /// ``AssetCacheService/touch(_:asset:token:)`` to retract a disk write
    /// that landed successfully but was only afterward discovered to
    /// already have been superseded.
    func removeIfApplied(_ key: AssetCacheKey, token: AssetCacheService.CacheToken) async {
        guard let lockFD = try? await secureDirectory.acquireExclusiveLock() else { return }
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        guard appliedToken[key] == token else { return }
        _ = try? secureDirectory.remove(name: metadataFilename(for: key))
        try? secureDirectory.fsyncRootDirectory()
        cleanupSupersededPayloads(forKeyHash: key.digestHex, keeping: nil)
        appliedToken[key] = nil
    }

    /// `true` only for a string that is exactly 64 lowercase ASCII hex
    /// characters — the shape of a real SHA-256 hex digest, and the only
    /// shape ever safe to interpolate into a filesystem path derived from
    /// otherwise-untrusted on-disk metadata. In particular this rejects
    /// `/`, `..`, and any other path-traversal or delimiter-injection
    /// attempt a tampered metadata sidecar's `payloadSHA256Hex` field could
    /// otherwise smuggle into ``payloadFilename(keyHash:contentHash:)``.
    static func isValidContentHash(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
        }
    }
}

/// Not `private`: `AssetDiskCache+Recovery.swift` also decodes metadata
/// sidecars with this exact configuration during startup recovery.
///
/// A fresh instance per call, rather than a shared singleton, since
/// `JSONEncoder`/`JSONDecoder` are not documented as thread-safe for
/// concurrent `encode`/`decode` calls: multiple `AssetDiskCache` actor
/// instances (or concurrently running tests) could otherwise race on one
/// shared encoder/decoder's internal state. Constructing one is cheap
/// (only setting a date strategy), so this costs nothing meaningful per
/// call.
extension JSONEncoder {
    static func assetCache() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static func assetCache() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
