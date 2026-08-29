import Foundation

/// Whole-cache eviction for ``AssetCacheService``, split out of the main
/// file purely to stay under this package's file-length limit.
extension AssetCacheService {
    /// Evicts every entry from both cache layers. Exposed for tests and for
    /// an explicit user-initiated "clear cache" action; never called
    /// automatically.
    ///
    /// Bumps the shared global epoch *before* awaiting either cache
    /// layer's removal, so every operation already in flight (a normal
    /// fetch's eventual publish, or a revalidation's eventual 404/304/200
    /// outcome) that captured its epoch before this call can no longer
    /// pass its own CAS check once this returns — none of them can
    /// resurrect anything this call is in the middle of clearing. Also
    /// cancels every currently in-flight fetch/revalidation task itself
    /// (not merely invalidating their eventual epoch check), so a caller
    /// that asked to clear the cache does not keep paying for network
    /// work whose result is now guaranteed to be discarded.
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
        globalEpoch += 1
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
            do {
                let survivingKeys = try await diskCache.entryKeyHashes()
                    .map { AssetCacheKey(digestHex: $0) }
                tombstonedKeys.formUnion(survivingKeys)
            } catch {
                // Cannot even enumerate what remains: there is no specific
                // key identity left to tombstone. `lastDiskPersistenceFailure`
                // below is the only remaining signal that this eviction did
                // not durably confirm a fully cleared disk cache.
            }
            lastDiskPersistenceFailure = error as? AssetError
                ?? .cachePersistenceFailed(String(describing: error))
        }
    }
}
