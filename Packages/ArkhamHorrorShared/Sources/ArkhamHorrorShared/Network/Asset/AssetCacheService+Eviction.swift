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
        // `AssetDiskCache.removeAll()` collects a failure *count*, not the
        // identities of whichever entries could not be removed — snapshot
        // every key persisted on disk *before* attempting removal, so a
        // partial failure can still conservatively tombstone every key
        // that was at risk, rather than only the ones already tombstoned
        // beforehand (which would let an untouched-but-undeletable entry
        // keep being served from disk after a claimed "clear cache").
        let precedingDiskKeys = await diskCache.entries().map { AssetCacheKey(digestHex: $0.hash) }
        do {
            try await diskCache.removeAll()
            tombstonedKeys.removeAll()
        } catch {
            // A partial disk removal failure does not invalidate the
            // epoch bump above (every in-flight/future operation is
            // already correctly gated by it), but this actor cannot prove
            // every entry was physically removed — tombstone every key
            // that was on disk immediately before this attempt (in
            // addition to whatever was already tombstoned) so a read can
            // never resurrect whatever could not be deleted. Newly
            // published keys after this point are unaffected:
            // `publish`/`touch` always clear a key's own tombstone on a
            // fresh, successful write.
            tombstonedKeys.formUnion(precedingDiskKeys)
            lastDiskPersistenceFailure = error as? AssetError
                ?? .cachePersistenceFailed(String(describing: error))
        }
    }
}
