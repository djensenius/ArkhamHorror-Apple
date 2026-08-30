import Foundation

/// Authority-key tracking/pruning subsystem for ``AssetCacheService``:
/// bounding how many distinct cache keys' authority bookkeeping
/// (`keyLatestToken`/`keyClearGeneration`) this actor retains at once,
/// and the paired begin/end "authority window" mechanism that protects a
/// key from being pruned while genuinely still suspended mid-operation.
/// Split out of `AssetCacheService+Epoch.swift` purely to keep that file
/// within this package's file/type-length conventions; still part of the
/// single `AssetCacheService` actor's isolated state.
extension AssetCacheService {
    /// Records `key` in ``AssetCacheService/authorityKeyOrder`` the first
    /// time it is ever seen by ``issueToken(for:)``,
    /// ``beginAuthorityWindow(for:)``, or ``invalidate(_:token:)``'s
    /// clear-generation bump, then prunes the oldest tracked keys'
    /// bookkeeping from both ``AssetCacheService/keyLatestToken``/
    /// ``keyClearGeneration`` once the number of distinct tracked keys
    /// exceeds ``AssetCacheService/maxTrackedAuthorityKeys`` — see that
    /// constant's own doc comment for why this bound exists at all.
    ///
    /// A key currently referenced by ``AssetCacheService/inFlight`` or
    /// ``AssetCacheService/inFlightRevalidation`` is never pruned: doing
    /// so would delete the very authority state a live operation for that
    /// exact key is about to check itself against, silently turning a
    /// perfectly legitimate in-progress fetch/revalidation into one that
    /// spuriously (and wrongly) finds itself no longer authoritative the
    /// next time it checks. Such a key is instead put back at the front
    /// of the queue exactly as it was, and the scan continues over the
    /// next-oldest entries; the scan itself is bounded to at most one
    /// full pass over the keys present when this call began, so a
    /// workload with more distinct keys genuinely in flight at once than
    /// `maxTrackedAuthorityKeys` simply — and safely — exceeds the
    /// nominal bound for as long as that burst of concurrency lasts,
    /// rather than looping forever or discarding live authority state.
    func noteAuthorityKeyTouched(_ key: AssetCacheKey) {
        if trackedAuthorityKeys.insert(key).inserted {
            authorityKeyOrder.append(key)
        }
        pruneAuthorityKeysIfNeeded()
    }

    private func pruneAuthorityKeysIfNeeded() {
        guard authorityKeyOrder.count > Self.maxTrackedAuthorityKeys else { return }
        var attemptsRemaining = authorityKeyOrder.count
        while authorityKeyOrder.count > Self.maxTrackedAuthorityKeys, attemptsRemaining > 0 {
            attemptsRemaining -= 1
            let oldest = authorityKeyOrder.removeFirst()
            guard !isAuthorityKeyBusy(oldest) else {
                authorityKeyOrder.append(oldest)
                continue
            }
            trackedAuthorityKeys.remove(oldest)
            keyLatestToken[oldest] = nil
            keyClearGeneration[oldest] = nil
        }
    }

    /// `true` if `key` currently has a normal fetch or a revalidation
    /// actually in flight, or currently has any other open "authority
    /// window" — a snapshot or token captured before a suspension whose
    /// eventual comparison still depends on this key's bookkeeping
    /// remaining exactly as it was (see ``beginAuthorityWindow(for:)``) —
    /// see ``noteAuthorityKeyTouched(_:)`` for why such a key's authority
    /// bookkeeping must never be pruned.
    private func isAuthorityKeyBusy(_ key: AssetCacheKey) -> Bool {
        if inFlight[key] != nil {
            return true
        }
        if inFlightRevalidation.keys.contains(where: { $0.cacheKey == key }) {
            return true
        }
        return (openAuthorityWindows[key] ?? 0) > 0
    }

    /// Opens an "authority window" for `key`: call immediately before
    /// capturing a ``snapshotAuthority(for:)`` result or an
    /// ``issueToken(for:)`` result that must remain valid across a
    /// subsequent suspension not otherwise tracked by ``inFlight``/
    /// ``inFlightRevalidation`` — the disk-hit branches of ``asset(for:)``
    /// and ``revalidate(for:)``, and their own memory-hit snapshots. Pair
    /// with a `defer { endAuthorityWindow(for: cacheKey) }` immediately
    /// after opening, so the window closes exactly once that specific
    /// snapshot/token's comparison has been fully resolved (a value
    /// returned, or the branch falls through to a fresh, independently
    /// tracked fetch/revalidation) — regardless of which exit path is
    /// taken, including a thrown error.
    ///
    /// Without this, ``pruneAuthorityKeysIfNeeded()`` could discard
    /// `key`'s bookkeeping while such a window is genuinely still open,
    /// and a subsequent fresh operation for the same key could then
    /// restart `key`'s ``keyClearGeneration`` at `0` — the exact value
    /// the still-suspended snapshot itself captured *before* any real
    /// invalidation happened — letting it wrongly observe "unchanged"
    /// after resuming even though a genuine invalidate/clear occurred in
    /// between (a classic ABA hazard). Tracked as a count (not a flag):
    /// two overlapping windows for the same key (for example, ordinary
    /// concurrent callers both taking the disk-hit branch) must not let
    /// the first to finish prematurely reopen the key to pruning while
    /// the second is still relying on it.
    func beginAuthorityWindow(for key: AssetCacheKey) {
        noteAuthorityKeyTouched(key)
        openAuthorityWindows[key, default: 0] += 1
    }

    /// Closes one authority window previously opened by
    /// ``beginAuthorityWindow(for:)`` for `key`. Safe to call even if no
    /// window is currently recorded (defensive; should not happen given
    /// the `defer`-paired call convention above).
    func endAuthorityWindow(for key: AssetCacheKey) {
        guard let count = openAuthorityWindows[key] else { return }
        if count <= 1 {
            openAuthorityWindows[key] = nil
        } else {
            openAuthorityWindows[key] = count - 1
        }
    }
}
