import Foundation

/// The unified mutation authority shared by every cache-mutating operation
/// on ``AssetCacheService``: a normal fetch's eventual publish
/// (``AssetCacheService/asset(for:)``), a revalidation's eventual
/// 404/304/200 outcome (``AssetCacheService/performRevalidation(_:)``),
/// and ``AssetCacheService/evictAll()``. Split out of
/// `AssetCacheService.swift`/`AssetCacheService+Revalidation.swift` purely
/// to keep those files within this package's `file_length` convention.
///
/// Every one of those operations suspends at least once (a network round
/// trip; for a disk hit, a disk-cache actor hop and a full platform
/// decode) between the moment it starts and the moment it would mutate
/// shared cache state, and two overlapping operations for the same key
/// can complete in an order that has nothing to do with the order they
/// were *issued* in (whichever suspends longer simply finishes later). A
/// design that only asks "has anything changed since I started" cannot
/// tell those two situations apart: if an older-issued operation happens
/// to finish first, nothing has changed yet, so it would wrongly be
/// treated as still authoritative — and the *actually* newer-issued
/// operation, finishing later, would then find its own naive "unchanged"
/// check now failing and be wrongly rejected. ``CacheToken`` instead
/// records *issuance* order directly: authority belongs to whichever
/// operation was issued last for a given key, full stop, regardless of
/// completion order.
///
/// - ``AssetCacheService/keyLatestToken``: the single token recorded as
///   authoritative for a key — always the most recently *issued* one,
///   never merely the most recently *completed* one.
/// - ``AssetCacheService/globalGeneration``: bumped once by
///   ``AssetCacheService/evictAll()``, invalidating every token already
///   issued for every key at once (including keys not yet present in
///   `keyLatestToken` at all) without needing to enumerate them.
///
/// A `CacheToken` is issued exactly once, synchronously, at the moment an
/// operation is *issued* (never re-issued later for that same logical
/// operation; coalesced waiters share the one token issued when the
/// shared operation itself began), and checked via
/// ``AssetCacheService/isAuthoritative(_:for:)`` immediately before every
/// point that operation is about to touch memory/disk state — including
/// again after a further suspension, if one occurs between two such
/// checks — and independently re-checked *inside* ``AssetMemoryCache``
/// and ``AssetDiskCache`` themselves (see their own `token:`-accepting
/// entry points), so a stale write can never land even if this actor's
/// own outer check happened to pass moments before a newer operation's
/// issuance. A 404, a 304, and a fresh 200 are all gated identically:
/// none of them is treated as unconditionally authoritative regardless of
/// timing, because a *stale* 404 (a slow response to an old request,
/// completing after a newer request already published fresh content) is
/// just as capable of wrongly resurrecting/destroying state as a stale
/// 304 or 200 would be.
extension AssetCacheService {
    /// A single key's issuance-ordered authority token: `generation`
    /// tracks cache-wide invalidation (``evictAll()``), `issuance` tracks
    /// this exact key's own strictly-increasing issuance order (drawn
    /// from a single counter shared across every key — see
    /// ``issueToken(for:)``). `Comparable` purely so `(generation,
    /// issuance)` tuple comparisons read naturally at call sites; two
    /// tokens for *different* keys are never meaningfully compared to
    /// each other.
    ///
    /// This cache does not attempt to durably order writes *across*
    /// separate processes/instances sharing the same disk directory —
    /// see ``AssetDiskCache``'s own doc comment for why a disk-only hit
    /// is instead always required to pass a fresh online conditional
    /// revalidation before being trusted/served, which makes a
    /// cross-process write-ordering guarantee unnecessary for
    /// correctness: "last physical writer wins" is an acceptable outcome
    /// (the same one an ordinary HTTP disk cache offers) as long as nothing
    /// is ever *served* without independently verifying its freshness
    /// first.
    struct CacheToken: Equatable, Sendable, Comparable {
        let generation: Int
        let issuance: Int
        /// This key's ``AssetCacheService/keyClearGeneration`` value at the
        /// moment this token was issued (see ``issueToken(for:)``) --
        /// *not* merely part of `==`/`<`'s identity comparison (two
        /// copies of the same issued token always agree on this by
        /// construction) but the value ``isAuthoritative(_:for:)``/
        /// ``unchanged(since:for:)`` compare against `key`'s *current*
        /// ``AssetCacheService/keyClearGeneration`` at check time. A
        /// real, targeted ``invalidate(_:token:)`` (a definitive 404, a
        /// failed re-validation quarantine) or a cache-wide
        /// ``evictAll()`` bumps that current value; a token issued
        /// *before* such a bump can therefore never again satisfy that
        /// comparison once it has happened, regardless of whether
        /// `keyLatestToken` itself still names this exact token. Folding
        /// this into every authority check (rather than only some of
        /// them, via a separate, narrower "clear state" check) is what
        /// lets an ordinary memory/disk hit and a revalidation both
        /// detect the exact same class of invalidation race uniformly.
        var clearGeneration: Int = 0

        static func == (lhs: CacheToken, rhs: CacheToken) -> Bool {
            lhs.generation == rhs.generation && lhs.issuance == rhs.issuance
        }

        static func < (lhs: CacheToken, rhs: CacheToken) -> Bool {
            (lhs.generation, lhs.issuance) < (rhs.generation, rhs.issuance)
        }
    }

    /// The outcome of a single authority-gated cache mutation
    /// (``publish(_:asset:token:)``, ``touch(_:asset:token:)``,
    /// ``invalidate(_:token:)``): `.applied` only if every one of that
    /// mutation's own internal authority re-checks passed and its write
    /// actually reached the requested layer(s); `.stale` if any of them
    /// found a more-recently-issued token (or a cache-wide
    /// ``evictAll()``) already authoritative by the time that check ran,
    /// in which case the mutation is a deliberate no-op. Callers that
    /// otherwise would have returned a value to their own caller as if a
    /// mutation had landed (see `AssetCacheService+Fetch.swift`'s and
    /// `AssetCacheService+RevalidationCoalescing.swift`'s use of this)
    /// must check this result rather than assuming `Void` success, so a
    /// caller never hands back a result whose own cache-side effects the
    /// system already knows were discarded as stale.
    enum MutationOutcome: Equatable, Sendable {
        case applied
        case stale
    }

    /// Retires `token` as the authoritative token for `key`, but only if
    /// it is still exactly the current one — never clobbering a
    /// more-recently-issued token that has already superseded it (nothing
    /// to do in that case: the newer token's own authority is already
    /// intact and must not be disturbed).
    ///
    /// Called when the last waiter for a coalesced fetch/revalidation
    /// cancels (see `AssetCacheService+Coalescing.swift`'s
    /// ``AssetCacheService/cancelWaiter(_:fetchID:waiterID:)`` and
    /// `AssetCacheService+RevalidationCoalescing.swift`'s
    /// ``AssetCacheService/cancelRevalidationWaiter(_:fetchID:waiterID:)``):
    /// the underlying work is about to be told to cancel, and — beyond
    /// cooperative `Task` cancellation, which the shared task may not
    /// observe until its next suspension point — nothing should be able
    /// to publish under this now-abandoned token afterward. Retiring the
    /// token here, synchronously and before the task is actually told to
    /// cancel, closes that window immediately rather than relying solely
    /// on cooperative cancellation checks: every subsequent
    /// ``isAuthoritative(_:for:)`` check the now-doomed task performs
    /// (inside ``publish(_:asset:token:)``/``touch(_:asset:token:)``/
    /// ``invalidate(_:token:)``, or in its own body before calling any of
    /// them) will find no token authoritative for `key` at all, and
    /// therefore correctly refuse to mutate shared state.
    func retireIfCurrent(_ token: CacheToken, for key: AssetCacheKey) {
        guard keyLatestToken[key] == token else { return }
        keyLatestToken[key] = nil
    }

    /// Issues a fresh, strictly-increasing authority token for `key`, and
    /// immediately records it as the sole currently-authoritative token
    /// for that key — superseding whatever token (if any) was previously
    /// authoritative, even one belonging to an operation still in flight.
    /// Callers issuing a fresh (never coalesced-into) operation call this
    /// exactly once, synchronously, before creating the `Task` that will
    /// eventually mutate state.
    func issueToken(for key: AssetCacheKey) -> CacheToken {
        noteAuthorityKeyTouched(key)
        // A single global, never-reset counter -- not a per-key one --
        // so that even after `key`'s own bookkeeping is pruned (see
        // ``pruneAuthorityKeysIfNeeded()``) and later restarts from
        // scratch, a freshly issued token for `key` can never carry the
        // exact same `issuance` value an older, still-suspended
        // snapshot/token for `key` (from before the prune) might still be
        // comparing against: issuance numbers are never reused, for any
        // key, for the lifetime of this actor.
        nextGlobalIssuance += 1
        let token = CacheToken(
            generation: globalGeneration,
            issuance: nextGlobalIssuance,
            clearGeneration: keyClearGeneration[key] ?? 0
        )
        keyLatestToken[key] = token
        return token
    }

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

    /// `true` only if `token` is still exactly the single most-recently
    /// *issued* token for `key`, under the current global generation, and
    /// `key` has not been individually invalidated since `token` was
    /// issued — the compare half of every mutating call site's
    /// compare-and-swap. An operation issued before another one for the
    /// same key can never pass this check again once the later one has
    /// been issued (nor after `key` is individually invalidated or the
    /// whole cache is cleared), regardless of which one's network round
    /// trip or decode happens to finish first.
    func isAuthoritative(_ token: CacheToken, for key: AssetCacheKey) -> Bool {
        token.generation == globalGeneration
            && keyLatestToken[key] == token
            && token.clearGeneration == (keyClearGeneration[key] ?? 0)
    }

    /// Invalidates every currently-issued token across every key at once.
    /// Called exactly by ``evictAll()``: every operation already in
    /// flight for any key captured its token under the generation this
    /// bumps past, so every one of them will find ``isAuthoritative(_:for:)``
    /// `false` from this point on without this needing to enumerate a
    /// single key.
    func issueGlobalInvalidation() {
        globalGeneration += 1
        keyLatestToken.removeAll()
        keyClearGeneration.removeAll()
        authorityKeyOrder.removeAll()
        trackedAuthorityKeys.removeAll()
    }
}
