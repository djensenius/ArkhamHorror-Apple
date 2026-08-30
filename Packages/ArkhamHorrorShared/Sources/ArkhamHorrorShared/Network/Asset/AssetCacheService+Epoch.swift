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
/// - ``AssetCacheService/keyIssuance``: the highest issuance number ever
///   handed out for one specific key, incremented by every fresh
///   (never-coalesced) operation at the moment it is issued.
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
    /// this exact key's own strictly-increasing issuance order.
    /// `Comparable` purely so `(generation, issuance)` tuple comparisons
    /// read naturally at call sites; two tokens for *different* keys are
    /// never meaningfully compared to each other.
    ///
    /// `diskBaselineGeneration` is a *second*, independent authority this
    /// token carries: the durable, on-disk write-generation this
    /// operation observed for its key at (or shortly after) issuance,
    /// captured via ``withDiskBaseline(_:for:)``. `generation`/`issuance`
    /// alone are purely in-process counters that start independently from
    /// zero in every separate process/instance sharing this same disk
    /// cache directory, so they cannot detect a stale write racing
    /// against a *different* process's own `AssetCacheService`/
    /// `AssetDiskCache`. `diskBaselineGeneration` closes that gap:
    /// ``AssetDiskCache`` compares it against the current on-disk
    /// generation for the key, inside the same exclusive lock as the
    /// write itself, immediately before ever publishing/touching/removing
    /// anything — see that type's own doc comment for the full contract.
    /// Deliberately excluded from `==`/`<` below (which govern *issuance*
    /// identity/ordering only, exactly as before this field existed): two
    /// tokens are still "the same token" for every in-process authority
    /// check regardless of whether ``withDiskBaseline(_:for:)`` has yet
    /// filled this field in.
    struct CacheToken: Equatable, Sendable, Comparable {
        let generation: Int
        let issuance: Int
        var diskBaselineGeneration: Int = 0

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
        let nextIssuance = (keyIssuance[key] ?? 0) + 1
        keyIssuance[key] = nextIssuance
        let token = CacheToken(generation: globalGeneration, issuance: nextIssuance)
        keyLatestToken[key] = token
        return token
    }

    /// Records `key` in ``AssetCacheService/authorityKeyOrder`` the first
    /// time it is ever seen by ``issueToken(for:)`` or
    /// ``invalidate(_:token:)``'s clear-generation bump, then prunes the
    /// oldest tracked keys' bookkeeping from all three of
    /// ``AssetCacheService/keyIssuance``/``keyLatestToken``/
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
            keyIssuance[oldest] = nil
            keyLatestToken[oldest] = nil
            keyClearGeneration[oldest] = nil
        }
    }

    /// `true` if `key` currently has a normal fetch or a revalidation
    /// actually in flight — see ``noteAuthorityKeyTouched(_:)`` for why
    /// such a key's authority bookkeeping must never be pruned.
    private func isAuthorityKeyBusy(_ key: AssetCacheKey) -> Bool {
        if inFlight[key] != nil {
            return true
        }
        return inFlightRevalidation.keys.contains { $0.cacheKey == key }
    }

    /// Captures the durable on-disk write-generation `key` currently has
    /// (see ``AssetDiskCache/currentWriteGeneration(for:)``) into a copy
    /// of `token`, and — only if `token` is still exactly the current
    /// authoritative token for `key` — re-records that stamped copy as
    /// the authoritative one, so every later
    /// ``isAuthoritative(_:for:)``/``publish(_:asset:token:)``/
    /// ``touch(_:asset:token:)``/``invalidate(_:token:)`` call site
    /// observes the stamped baseline rather than the placeholder
    /// ``CacheToken/diskBaselineGeneration`` value `issueToken(for:)`
    /// itself always constructs a token with (0, never meaningfully
    /// compared until this call fills it in).
    ///
    /// Deliberately never called from inside the same synchronous
    /// section that decides whether to create a fresh, never
    /// coalesced-into `Task`/`inFlight`(`Revalidation`) entry — this
    /// method's own disk read is a genuine suspension, and suspending
    /// between that decision and actually recording the new work would
    /// let a second concurrent caller for the same key also observe "no
    /// existing in-flight work" and start its own separate, duplicate
    /// fetch, breaking the "coalesce exact identical in-flight work"
    /// contract. Every call site instead calls this from *inside* the
    /// already-registered `Task`'s own body — ``fetchAndValidate(key:cacheKey:candidates:token:)``
    /// and ``performRevalidation(_:)``, whose single call sites are each
    /// the sole place their respective in-flight work performs any
    /// network I/O — or, for the two disk-hit revalidation branches
    /// (`asset(for:)`'s and `revalidate(for:)`'s), immediately after
    /// `issueToken(for:)` itself, since neither of those two call sites
    /// is behind any coalescing dictionary at all.
    ///
    /// If a more-recently-issued token has already superseded `token`
    /// while this call was suspended, the stamped copy is still returned
    /// (so the caller's own subsequent ``isAuthoritative(_:for:)`` checks
    /// — which ignore this field entirely — behave exactly as if this
    /// call had never run), but `keyLatestToken` itself is left
    /// untouched: the newer token's own authority must not be disturbed
    /// by this now-stale one being re-stamped over it.
    func withDiskBaseline(_ token: CacheToken, for key: AssetCacheKey) async -> CacheToken {
        let baseline = await diskCache.currentWriteGeneration(for: key)
        var stamped = token
        stamped.diskBaselineGeneration = baseline
        if keyLatestToken[key] == token {
            keyLatestToken[key] = stamped
        }
        return stamped
    }

    /// `true` only if `token` is still exactly the single most-recently
    /// *issued* token for `key`, under the current global generation —
    /// the compare half of every mutating call site's compare-and-swap.
    /// An operation issued before another one for the same key can never
    /// pass this check again once the later one has been issued,
    /// regardless of which one's network round trip or decode happens to
    /// finish first.
    func isAuthoritative(_ token: CacheToken, for key: AssetCacheKey) -> Bool {
        token.generation == globalGeneration && keyLatestToken[key] == token
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
        keyIssuance.removeAll()
        keyClearGeneration.removeAll()
        authorityKeyOrder.removeAll()
        trackedAuthorityKeys.removeAll()
    }

    /// A read-only snapshot of `key`'s current authority state, taken
    /// immediately *before* a disk read whose result must not be trusted
    /// if that authority changes while the read is suspended -- see
    /// ``unchanged(since:for:)``. Deliberately does **not** call
    /// ``issueToken(for:)``: a disk-hit lookup that turns out to be a
    /// miss, or whose read loses the race checked by
    /// ``unchanged(since:for:)``, must never have consumed an issuance
    /// number or clobbered whatever fetch is (or is about to be) legitimately
    /// in flight for this key -- unlike a snapshot, issuing a token is
    /// never a no-op: it unconditionally supersedes the current
    /// authoritative token for `key`, which would wrongly invalidate an
    /// already-in-flight coalesced fetch's own token merely because a
    /// second, ultimately-coalescing caller also happened to pass through
    /// this same disk-hit code path.
    func snapshotAuthority(for key: AssetCacheKey) -> (token: CacheToken?, generation: Int) {
        (keyLatestToken[key], globalGeneration)
    }

    /// `true` only if `key`'s authority state is *exactly* what
    /// ``snapshotAuthority(for:)`` observed it to be, immediately before a
    /// disk read this call now wants to trust the result of. A mismatch
    /// means some other operation -- a more-recently-issued fetch or
    /// revalidation for this exact key, or a cache-wide ``evictAll()`` --
    /// became authoritative for this key while the read was suspended, so
    /// the read's result (even if it returned a value) must not be
    /// promoted into memory or used as the basis for a conditional
    /// request: see ``asset(for:)``'s and ``revalidate(for:)``'s own
    /// disk-hit branches.
    func unchanged(
        since snapshot: (token: CacheToken?, generation: Int),
        for key: AssetCacheKey
    ) -> Bool {
        keyLatestToken[key] == snapshot.token && globalGeneration == snapshot.generation
    }

    /// A read-only snapshot of `key`'s current *clear* state — narrower
    /// than ``snapshotAuthority(for:)``: it only changes when `key` is
    /// actually invalidated (``invalidate(_:token:)`` performing a real
    /// removal) or the whole cache is (``evictAll()``'s `globalGeneration`
    /// bump), never merely because *some* fresh, perfectly legitimate and
    /// coalescable operation was issued for this same key in the
    /// meantime.
    ///
    /// ``revalidate(for:)``'s memory-hit branch uses this — not
    /// ``snapshotAuthority(for:)``/``unchanged(since:for:)`` — to decide
    /// whether a cached value it is about to hand to
    /// ``revalidateExisting(_:key:cacheKey:candidates:)`` is still safe to
    /// mint a *fresh* authority token from. The coarser, token-based check
    /// would also (wrongly) trip whenever a second, concurrent
    /// ``revalidate(for:)``/``asset(for:)`` call for the exact same key
    /// happens to have already issued its own token by the time this one
    /// resumes from its own memory-cache read — a normal, entirely
    /// coalescable race, not an invalidation — which would otherwise force
    /// this call down the disk-hit branch purely due to timing, where its
    /// own *additional* token issuance could needlessly supersede (and so
    /// break) that sibling's already-appropriate, still-legitimate
    /// in-flight work. This check answers the narrower and actually
    /// relevant question instead: "was the specific cached value I just
    /// read invalidated out from under me", which only a real
    /// ``invalidate(_:token:)``/``evictAll()`` can make true.
    func snapshotClearState(for key: AssetCacheKey) -> (clear: Int, generation: Int) {
        (keyClearGeneration[key] ?? 0, globalGeneration)
    }

    /// `true` only if `key`'s clear state is exactly what
    /// ``snapshotClearState(for:)`` observed it to be — see that
    /// function's doc comment for why this is a deliberately narrower
    /// check than ``unchanged(since:for:)``.
    func clearStateUnchanged(
        since snapshot: (clear: Int, generation: Int),
        for key: AssetCacheKey
    ) -> Bool {
        (keyClearGeneration[key] ?? 0) == snapshot.clear && globalGeneration == snapshot.generation
    }
}
