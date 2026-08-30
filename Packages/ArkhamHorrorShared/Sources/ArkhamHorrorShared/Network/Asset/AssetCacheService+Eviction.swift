import Foundation

/// Whole-cache eviction for ``AssetCacheService``, split out of the main
/// file purely to stay under this package's file-length limit.
extension AssetCacheService {
    /// Evicts every entry from both cache layers. Exposed for tests and for
    /// an explicit user-initiated "clear cache" action; never called
    /// automatically.
    ///
    /// Issues a global invalidation *before* awaiting either cache
    /// layer's removal, so every operation already in flight (a normal
    /// fetch's eventual publish, or a revalidation's eventual 404/304/200
    /// outcome) that issued its token before this call can no longer
    /// pass its own authority check once this returns — none of them can
    /// resurrect anything this call is in the middle of clearing. Also
    /// cancels every currently in-flight fetch/revalidation task itself
    /// (not merely invalidating their eventual authority check), so a
    /// caller that asked to clear the cache does not keep paying for
    /// network work whose result is now guaranteed to be discarded.
    ///
    /// Every already-registered waiter for a fetch/revalidation this call
    /// is about to tear down is resumed (with `CancellationError`)
    /// synchronously here, *before* its entry is removed from
    /// `inFlight`/`inFlightRevalidation` — this is required, not merely
    /// cosmetic: a plain `task.cancel()` never itself resumes a waiter's
    /// continuation; only that shared task's own completion watcher
    /// (``completeFetch(_:fetchID:result:)``/
    /// ``completeRevalidation(_:fetchID:result:)``) or a specific waiter's
    /// own cancellation handler (``cancelWaiter(_:fetchID:waiterID:)``/
    /// ``cancelRevalidationWaiter(_:fetchID:waiterID:)``) do that, and
    /// once this method has already removed an entry, that entry's own
    /// completion watcher finds nothing left to match (`fetch.id ==
    /// fetchID` fails) and silently returns without resuming anything.
    /// Without this, a caller still suspended in ``coalescedFetch``/
    /// ``coalescedRevalidation`` at the moment this method ran would hang
    /// forever instead of observing `CancellationError`.
    func evictAll() async {
        issueGlobalInvalidation()
        for (_, fetch) in inFlight {
            for (_, continuation) in fetch.waiters {
                continuation.resume(returning: .failure(CancellationError()))
            }
            fetch.task.cancel()
        }
        for (_, fetch) in inFlightRevalidation {
            for (_, continuation) in fetch.waiters {
                continuation.resume(returning: .failure(CancellationError()))
            }
            fetch.task.cancel()
        }
        inFlight.removeAll()
        inFlightRevalidation.removeAll()
        await memoryCache.removeAll()
        do {
            try await diskCache.removeAll()
            tombstonedKeys.removeAll()
            lastDiskPersistenceFailure = nil
        } catch {
            // `removeAll()` failed (partially or entirely): some entries
            // may still be physically present on disk. Snapshot *after*
            // this failed attempt, not before it — a pre-attempt snapshot
            // (via a separate, independently racy listing call) can never
            // be proven consistent with what `removeAll()` itself actually
            // saw or removed, and silently degrading that separate
            // snapshot to "no keys" on its own listing failure would let
            // an undeletable entry go completely untombstoned. Listing
            // the directory now instead reflects exactly what survived
            // this exact attempt (correctly excluding whatever
            // `removeAll()` did manage to remove before failing).
            //
            // `entryKeyHashes()` deliberately returns every raw filename
            // prefix it finds, including one from a corrupt/tampered/
            // attacker-controlled entry that would never actually decode
            // as a real key hash. Filter to only the 64-lowercase-hex
            // shape a genuine key hash always has (the same shape
            // ``AssetDiskCache/isValidContentHash(_:)`` already enforces
            // for content hashes) before ever constructing an
            // ``AssetCacheKey`` from it or growing `tombstonedKeys` with
            // it — an unfiltered, arbitrarily-many, arbitrarily-long
            // directory entry name must never be able to inflate this
            // in-memory set without bound.
            do {
                let survivingKeys = try await diskCache.entryKeyHashes()
                    .filter { AssetDiskCache.isValidContentHash($0) }
                    .map { AssetCacheKey(digestHex: $0) }
                tombstonedKeys.formUnion(survivingKeys)
            } catch {
                // Cannot even enumerate what remains: there is no specific
                // key identity left to tombstone individually. Fail
                // closed for the *entire* disk cache instead — every
                // subsequent `get(_:)` refuses every entry until a fully
                // successful `removeAll()` later durably clears this
                // marker — rather than silently risking a stale entry
                // this call could not identify still being served.
                await diskCache.markDiskReadsDisabled()
            }
            lastDiskPersistenceFailure = error as? AssetError
                ?? .cachePersistenceFailed(String(describing: error))
        }
    }

    /// Removes `cacheKey` from both cache layers, tombstoning it if the
    /// disk deletion could not be confirmed to fully succeed (see
    /// ``tombstonedKeys``). Centralizes every disk-invalidating call site
    /// (a definitive 404, a failed re-validation quarantine) so none of
    /// them can accidentally swallow a deletion failure the way a bare
    /// `try?`/best-effort `remove` used to.
    ///
    /// `token` is optional: a re-validation quarantine
    /// (``revalidateDiskHit(_:key:cacheKey:candidates:token:)``'s own
    /// `catch`) still passes its caller's token so this stays gated like
    /// every other mutation, but this is also called with no token at all
    /// from contexts that are not part of any issuance race (there is no
    /// prior in-flight operation whose authority could be superseded).
    /// Returns ``MutationOutcome/stale`` under the same conditions
    /// ``publish(_:asset:token:)`` does (only ever possible when `token`
    /// is non-`nil`: a `nil` token has no authority to lose).
    @discardableResult
    func invalidate(_ cacheKey: AssetCacheKey, token: CacheToken? = nil) async -> MutationOutcome {
        if let token, !isAuthoritative(token, for: cacheKey) {
            return .stale
        }
        // Recorded *before* the memory removal itself (the actual
        // suspension below), so a concurrent reader that snapshotted
        // ``keyClearGeneration`` before this call started will correctly
        // observe a change even if it resumes while this call is still
        // suspended partway through — see ``snapshotClearState(for:)``'s
        // doc comment for why this is deliberately a distinct counter
        // from ``keyLatestToken``.
        noteAuthorityKeyTouched(cacheKey)
        keyClearGeneration[cacheKey, default: 0] += 1
        await memoryCache.remove(cacheKey, token: token)
        if let token, !isAuthoritative(token, for: cacheKey) {
            return .stale
        }
        do {
            try await diskCache.remove(cacheKey, token: token)
            lastDiskPersistenceFailure = nil
        } catch let error as AssetError {
            tombstonedKeys.insert(cacheKey)
            lastDiskPersistenceFailure = error
        } catch {
            tombstonedKeys.insert(cacheKey)
            lastDiskPersistenceFailure = .cachePersistenceFailed(String(describing: error))
        }
        if let token, !isAuthoritative(token, for: cacheKey) {
            return .stale
        }
        return .applied
    }
}
