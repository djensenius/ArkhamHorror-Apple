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
    /// process per-key token CAS: accepts `token` only if its durable
    /// clear epoch still *exactly* matches the value the caller already
    /// read (under the same already-held exclusive lock) via
    /// ``SecureCacheDirectory/readPersistedClearEpoch()``, **and** its own
    /// issued ticket (``AssetCacheService/CacheToken/diskWriteGeneration``)
    /// is still `>=` the highest ticket any mutation for this key has
    /// actually applied so far (`currentApplied`, read via
    /// ``currentAppliedTicketLocked(for:)``) — never against any
    /// actor-local, in-memory bookkeeping, and never re-read internally
    /// here (the caller reads both exactly once, so it can reuse the same
    /// values to durably commit the next applied ticket immediately after
    /// a successful mutation, without a second, potentially-inconsistent
    /// read). A `nil` on either half of `token` (a durable read failure at
    /// issuance time) always rejects; there is no in-memory fallback.
    ///
    /// **Deliberately `>=`, not `==`.** An earlier revision compared
    /// `token`'s captured generation for *exact* equality against the
    /// current value — completion-ordered, not issuance-ordered: two
    /// operations issued concurrently for the same key, before either has
    /// published, could capture the *identical* snapshot, and whichever
    /// one's write merely *completed* first would "win" that equality
    /// check, wrongly rejecting a genuinely later-issued operation that
    /// simply took longer to reach this point. Comparing `>=` against the
    /// highest *applied* ticket instead only ever rejects a token whose
    /// own issued ticket has already been superseded by some other
    /// mutation's — regardless of which one's network round trip or
    /// decode happened to finish first — and this file's own
    /// ``reserveAndCommitMutationTicketLocked(for:)`` (invoked by every
    /// successful mutation immediately before it takes effect) guarantees
    /// every successfully applied ticket is itself always strictly higher
    /// than whatever was applied before it, so a stale token's own ticket
    /// can never again satisfy `>=` once any later ticket has applied.
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
        currentApplied: Int
    ) -> Bool {
        guard
            let expectedEpoch = token.durableClearEpoch,
            let issuedTicket = token.diskWriteGeneration
        else {
            return false
        }
        return currentEpoch == expectedEpoch && issuedTicket >= currentApplied
    }

    /// Removes `key`'s on-disk entry only if `token` is *exactly* the
    /// token whose own mutation is currently the last-applied one for
    /// this key — i.e. the current durable applied ticket is *exactly*
    /// `token`'s own issued ticket — and the durable clear epoch has not
    /// changed since. Deliberately exact-match, not the `>=` compare
    /// ``acceptToken(_:currentEpoch:currentApplied:)`` uses: by the time
    /// this runs, `token`'s own mutation has already durably become the
    /// applied ticket for this key (via
    /// ``reserveAndCommitMutationTicketLocked(for:)``), so this only ever
    /// retracts a mutation that is still exactly the current, unsuperseded
    /// state — never a token some other, later mutation has since moved
    /// past. Mirrors ``AssetMemoryCache/removeIfApplied(_:token:)``'s
    /// exact-match semantics. Used by
    /// ``AssetCacheService/publish(_:asset:token:)``/
    /// ``AssetCacheService/touch(_:asset:token:)`` to retract a disk write
    /// that landed successfully but was only afterward discovered to
    /// already have been superseded (e.g. the last waiter of a coalesced
    /// operation cancelled before delivery).
    func removeIfApplied(_ key: AssetCacheKey, token: AssetCacheService.CacheToken) async {
        guard let lockFD = try? await secureDirectory.acquireExclusiveLock() else { return }
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try? ensureRootAuthorityInitializedLocked()
        guard
            let issuedTicket = token.diskWriteGeneration,
            let issuedEpoch = token.durableClearEpoch,
            let currentEpoch = try? secureDirectory.readPersistedClearEpoch(),
            currentEpoch == issuedEpoch,
            let currentApplied = try? currentAppliedTicketLocked(for: key),
            currentApplied == issuedTicket
        else {
            return
        }
        _ = try? secureDirectory.remove(name: metadataFilename(for: key))
        try? secureDirectory.fsyncRootDirectory()
        cleanupSupersededPayloads(forKeyHash: key.digestHex, keeping: nil)
        // Advances the applied ticket one further step past this exact
        // retraction, mirroring every other successful mutation in this
        // file: leaves no window where a *third*, even-later-issued
        // token could still find `currentApplied == its own ticket` by
        // coincidence after this retraction, and correctly permits a
        // still-in-flight, genuinely newer operation for this same key to
        // freely proceed afterward.
        _ = try? reserveAndCommitMutationTicketLocked(for: key)
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
