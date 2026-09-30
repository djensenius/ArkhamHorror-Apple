import Foundation

/// A FIFO queue offering amortized O(1) `append`/`popFirst`, backing
/// ``AssetCacheService/authorityKeyOrder``. A bare `Array` used purely as
/// a queue (`append` at the back, `removeFirst()` at the front) costs
/// O(n) per `removeFirst()` — an element shift over everything still
/// remaining — since `Array` has no notion of "already-consumed" prefix
/// slots it can reclaim without moving the rest. During a sustained
/// all-keys-busy burst at ``AssetCacheService/maxTrackedAuthorityKeys``
/// capacity, ``AssetCacheService/noteAuthorityKeyTouched(_:)`` re-scans
/// (and requeues) every busy key on every single touch, so that O(n) cost
/// per removal would make the whole burst quadratic in the number of
/// touches. This type instead tracks a `head` cursor into a single
/// backing array, so `popFirst()` is an O(1) index bump, and only
/// occasionally (once consumed slots are a large-enough fraction of the
/// backing storage) compacts them away in one pass — amortized O(1)
/// overall, the same guarantee `Array.append` itself already gives for
/// growth.
struct AuthorityKeyQueue<Element: Sendable>: Sendable {
    private var storage: [Element] = []
    private var head = 0
    private var nextPruningAttemptCount: Int?

    /// The compaction threshold below which a mostly-empty prefix is left
    /// alone rather than paying a compaction pass for a handful of
    /// entries — purely to avoid compacting on every single pop once the
    /// queue is nearly empty (compaction itself is O(remaining), so
    /// doing it too eagerly at tiny sizes would make *popping* the
    /// quadratic operation instead).
    private static var minimumCompactionHead: Int {
        64
    }

    private static var deferredPruningOverflow: Int {
        64
    }

    var count: Int {
        storage.count - head
    }

    var isEmpty: Bool {
        head == storage.count
    }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    @discardableResult
    mutating func popFirst() -> Element? {
        guard head < storage.count else { return nil }
        let element = storage[head]
        head += 1
        compactIfNeeded()
        return element
    }

    mutating func removeAll() {
        storage.removeAll()
        head = 0
        nextPruningAttemptCount = nil
    }

    func shouldDeferPruning() -> Bool {
        nextPruningAttemptCount.map { count < $0 } ?? false
    }

    mutating func deferPruning() {
        nextPruningAttemptCount = count + Self.deferredPruningOverflow
    }

    mutating func clearDeferredPruning() {
        nextPruningAttemptCount = nil
    }

    /// Reclaims consumed prefix slots once they make up at least half of
    /// backing storage (and are a large-enough absolute count to be
    /// worth an O(remaining) pass at all) — keeping the backing array's
    /// true size bounded by roughly twice the queue's live element count,
    /// rather than growing forever across the queue's lifetime purely
    /// from popped-but-never-reclaimed prefix slots.
    private mutating func compactIfNeeded() {
        guard head >= Self.minimumCompactionHead, head * 2 >= storage.count else { return }
        storage.removeFirst(head)
        head = 0
    }
}

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
    /// `key` itself — the one this exact call is registering or
    /// re-touching — is always protected from this same pruning pass,
    /// even before its caller has had any chance to record it as "busy"
    /// via ``inFlight``/``inFlightRevalidation``/``openAuthorityWindows``
    /// (``issueToken(for:)`` in particular only sets
    /// ``AssetCacheService/keyLatestToken`` *after* this call returns).
    /// Without that self-protection, a `key` freshly inserted into
    /// ``authorityKeyOrder`` right when tracking is already at capacity
    /// with every other entry genuinely busy could immediately prune
    /// *itself* out of ``trackedAuthorityKeys``/``authorityKeyOrder``
    /// before its caller ever got to establish real liveness for it —
    /// after which ``issueToken(for:)`` would still go on to unconditionally
    /// write ``keyLatestToken[key]``, permanently orphaning that entry:
    /// present in the map forever, but no longer counted against (or
    /// reachable by) any future prune pass at all.
    ///
    /// A key currently referenced by ``AssetCacheService/inFlight`` or
    /// ``AssetCacheService/inFlightRevalidation`` is never pruned: doing
    /// so would delete the very authority state a live operation for that
    /// exact key is about to check itself against, silently turning a
    /// perfectly legitimate in-progress fetch/revalidation into one that
    /// spuriously (and wrongly) finds itself no longer authoritative the
    /// next time it checks. Such a busy key is instead requeued exactly
    /// as it was, and the scan continues over the next-oldest entries;
    /// the scan itself is bounded to at most one full pass over the keys
    /// present when this call began, so a workload with more distinct
    /// keys genuinely in flight at once than `maxTrackedAuthorityKeys`
    /// simply — and safely — exceeds the nominal bound for as long as
    /// that burst of concurrency lasts, rather than looping forever or
    /// discarding live authority state.
    func noteAuthorityKeyTouched(_ key: AssetCacheKey) {
        if trackedAuthorityKeys.insert(key).inserted {
            authorityKeyOrder.append(key)
        }
        pruneAuthorityKeysIfNeeded(protecting: key)
    }

    private func pruneAuthorityKeysIfNeeded(protecting protectedKey: AssetCacheKey) {
        guard authorityKeyOrder.count > Self.maxTrackedAuthorityKeys else {
            authorityKeyOrder.clearDeferredPruning()
            return
        }
        guard !authorityKeyOrder.shouldDeferPruning() else { return }
        var attemptsRemaining = authorityKeyOrder.count
        while authorityKeyOrder.count > Self.maxTrackedAuthorityKeys, attemptsRemaining > 0 {
            attemptsRemaining -= 1
            guard let oldest = authorityKeyOrder.popFirst() else { break }
            guard oldest != protectedKey, !isAuthorityKeyBusy(oldest) else {
                authorityKeyOrder.append(oldest)
                continue
            }
            trackedAuthorityKeys.remove(oldest)
            keyLatestToken[oldest] = nil
            keyClearGeneration[oldest] = nil
            // Pruned in the same bundle, for the identical reason: see
            // ``markGenerationRetiring(_:for:)``'s own doc comment for
            // why this is deliberately never cleared any earlier than
            // this — this key's own bookkeeping (including any still-
            // suspended reader's authority window) is only ever pruned
            // once ``isAuthorityKeyBusy(_:)`` above has already confirmed
            // nothing live still depends on it.
            retiringGenerations[oldest] = nil
            issuedAuthorityChain[oldest] = nil
        }
        if attemptsRemaining == 0 {
            authorityKeyOrder.deferPruning()
        } else {
            authorityKeyOrder.clearDeferredPruning()
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
        if (revalidationKeyRefCount[key] ?? 0) > 0 {
            return true
        }
        return (openAuthorityWindows[key] ?? 0) > 0
    }

    /// The sole mutation points for ``inFlightRevalidation``: every insert
    /// or removal of a slot must go through one of these two functions
    /// (never write ``inFlightRevalidation`` directly) so that
    /// ``revalidationKeyRefCount`` — the O(1) per-key "is a revalidation
    /// in flight for this key" lookup ``isAuthorityKeyBusy(_:)`` relies on
    /// — never drifts out of sync with the actual contents of
    /// ``inFlightRevalidation``.
    func setInFlightRevalidation(_ fetch: RevalidationFetch, for slot: RevalidationSlot) {
        if inFlightRevalidation.updateValue(fetch, forKey: slot) == nil {
            revalidationKeyRefCount[slot.cacheKey, default: 0] += 1
        }
    }

    @discardableResult
    func clearInFlightRevalidation(for slot: RevalidationSlot) -> RevalidationFetch? {
        guard let removed = inFlightRevalidation.removeValue(forKey: slot) else { return nil }
        let key = slot.cacheKey
        if let count = revalidationKeyRefCount[key] {
            if count <= 1 {
                revalidationKeyRefCount[key] = nil
            } else {
                revalidationKeyRefCount[key] = count - 1
            }
        }
        return removed
    }

    /// Removes every currently in-flight revalidation slot at once (used
    /// only by ``evictAll()``, which must discard every one regardless of
    /// key) and resets ``revalidationKeyRefCount`` alongside it in the
    /// same O(1)-ish sweep, rather than calling
    /// ``clearInFlightRevalidation(for:)`` once per slot.
    func removeAllInFlightRevalidation() {
        inFlightRevalidation.removeAll()
        revalidationKeyRefCount.removeAll()
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
    /// Without this, ``pruneAuthorityKeysIfNeeded(protecting:)`` could
    /// discard `key`'s bookkeeping while such a window is genuinely still
    /// open, and a subsequent fresh operation for the same key could then
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
