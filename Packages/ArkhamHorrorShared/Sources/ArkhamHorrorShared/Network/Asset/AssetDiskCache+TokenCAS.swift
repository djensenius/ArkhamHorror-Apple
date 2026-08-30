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
    /// comment for exactly what durably sets/clears that state.
    ///
    /// Unconditionally runs one fresh ``evictIfNeeded()`` recovery/
    /// accounting pass first — every single time this is called, not
    /// only when a disabled marker already happens to be set. This is
    /// what makes locked accounting/reservation complete *before* every
    /// publication, not merely after one: `set(_:payload:metadata:token:)`
    /// also unconditionally re-runs `evictIfNeeded()` again in its own
    /// `defer`, folding in whatever bytes that exact write itself just
    /// added — but without this call *also* running it first, the very
    /// first write ever made against a freshly-recovered, not-yet-marked-
    /// disabled directory (recovery having found some orphan/sidecar it
    /// could not confirm was actually reclaimed, or could not stat/
    /// enumerate) would sail straight past this guard (since the disabled
    /// marker only gets set *by* `evictIfNeeded()` itself, and this
    /// method previously only ever called it when the marker was already
    /// set) and publish new bytes into a directory whose true physical
    /// usage was never actually confirmed within budget beforehand at
    /// all. A marker left over from a since-resolved transient failure (a
    /// filesystem that was briefly full or read-only, for example) is not
    /// permanently stuck, either: this same fresh pass is exactly what
    /// clears it once conditions have genuinely improved, but a marker
    /// that persists even after this fresh attempt means physical usage
    /// genuinely cannot be confirmed or brought under budget right now,
    /// and this call's own new payload must not be allowed to make that
    /// unknown/over-budget state larger still.
    func requireDiskWritesEnabledLocked() throws {
        evictIfNeeded()
        guard !areDiskWritesDisabledLocked() else {
            throw AssetError.cachePersistenceFailed(
                "Disk writes are disabled: on-disk cache budget could not be confirmed"
            )
        }
    }

    /// The compare half of this cache's durable, cross-instance/cross-
    /// process per-key token CAS: accepts `token` only if **both** of its
    /// two durable authority halves still exactly match the values the
    /// caller already read (under the same already-held exclusive lock)
    /// via ``SecureCacheDirectory/readPersistedClearEpoch()`` and
    /// ``currentWriteGenerationLocked(for:)`` — never against any
    /// actor-local, in-memory bookkeeping, and never re-read internally
    /// here (the caller reads both exactly once, so it can reuse the same
    /// values to durably commit the next generation immediately after a
    /// successful mutation, without a second, potentially-inconsistent
    /// read). A `nil` on either half of `token` (a durable read failure
    /// at issuance time) always rejects; there is no in-memory fallback.
    ///
    /// This is what actually makes two independently wired instances/
    /// processes sharing this same on-disk directory agree on write
    /// ordering for the same key: an older instance's delayed publish/
    /// touch/removal can never overwrite or remove state a newer
    /// instance already concluded, regardless of which instance's own
    /// in-process bookkeeping thinks is current.
    ///
    /// Must only ever be called while the caller already holds this
    /// instance's ``SecureCacheDirectory/acquireExclusiveLock()`` — every
    /// call site (``AssetDiskCache/set(_:payload:metadata:token:)``'s
    /// `setLocked`, ``AssetDiskCache/touch(_:metadata:token:)``'s
    /// `touchLocked`, ``AssetDiskCache/remove(_:token:)``) already does.
    func acceptToken(
        _ token: AssetCacheService.CacheToken,
        currentEpoch: Int,
        currentGeneration: Int
    ) -> Bool {
        guard
            let expectedEpoch = token.durableClearEpoch,
            let expectedGeneration = token.diskWriteGeneration
        else {
            return false
        }
        return currentEpoch == expectedEpoch && currentGeneration == expectedGeneration
    }

    /// Removes `key`'s on-disk entry only if `token` is *exactly* the
    /// token whose own write is currently the last-applied one for this
    /// key — i.e. the current durable write generation is exactly one
    /// past what `token` itself captured at issuance (the value
    /// ``AssetDiskCache/commitWriteGenerationLocked(_:for:)`` durably
    /// persisted immediately after `token` passed
    /// ``acceptToken(_:for:)``'s own pre-write check) — and the durable
    /// clear epoch has not changed since. Deliberately a different
    /// comparison than ``acceptToken(_:for:)``'s own pre-write CAS: by
    /// the time this runs, `token`'s own write has *already* durably
    /// bumped the generation counter past the value `token` captured at
    /// issuance, so comparing against that same pre-write value again
    /// here would always (wrongly) reject the very token whose mutation
    /// this call exists to retract. Mirrors
    /// ``AssetMemoryCache/removeIfApplied(_:token:)``'s exact-match
    /// semantics (as opposed to ``acceptToken(_:for:)``'s "reject if a
    /// newer token already applied" compare-and-swap). Used by
    /// ``AssetCacheService/publish(_:asset:token:)``/
    /// ``AssetCacheService/touch(_:asset:token:)`` to retract a disk write
    /// that landed successfully but was only afterward discovered to
    /// already have been superseded.
    func removeIfApplied(_ key: AssetCacheKey, token: AssetCacheService.CacheToken) async {
        guard let lockFD = try? await secureDirectory.acquireExclusiveLock() else { return }
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        guard
            let issuedGeneration = token.diskWriteGeneration,
            let issuedEpoch = token.durableClearEpoch,
            let currentEpoch = try? secureDirectory.readPersistedClearEpoch(),
            currentEpoch == issuedEpoch,
            let currentGeneration = try? currentWriteGenerationLocked(for: key),
            currentGeneration == issuedGeneration + 1
        else {
            return
        }
        _ = try? secureDirectory.remove(name: metadataFilename(for: key))
        try? secureDirectory.fsyncRootDirectory()
        cleanupSupersededPayloads(forKeyHash: key.digestHex, keeping: nil)
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
