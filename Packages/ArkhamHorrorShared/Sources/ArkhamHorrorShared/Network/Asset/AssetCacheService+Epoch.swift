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
    /// This cache does not attempt to durably *order* writes *across*
    /// separate processes/instances sharing the same disk directory:
    /// "last physical writer wins" for the actual bytes of a fresh,
    /// otherwise-legitimate publish is an acceptable outcome (the same
    /// one an ordinary HTTP disk cache offers), and any disk-only hit
    /// is always independently required to pass a fresh online
    /// conditional revalidation before being trusted/served regardless
    /// (see ``AssetDiskCache``'s own doc comment). What this token *does*
    /// durably prevent across instances/processes, via
    /// ``durableClearEpoch``, is a *cleared* cache being resurrected or
    /// freshly re-populated by an operation whose authority a clear (in
    /// this or any other instance/process sharing the directory) already
    /// revoked before that operation's own mutation ran — including a
    /// mutation that only ever touches this instance's own private
    /// memory cache, which a disk-side revalidation requirement alone
    /// can never reach.
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
        /// The durable, cross-instance/cross-process
        /// ``SecureCacheDirectory/readPersistedClearEpoch()`` value
        /// observed at the moment this token was issued (see
        /// ``issueToken(for:)`` and `SecureCacheDirectory+ClearEpoch.swift`'s
        /// type-level doc comment) — `nil` only if that durable read
        /// itself failed at issuance time, which ``isAuthoritative(_:for:)``
        /// treats as permanently non-authoritative (fail closed) rather
        /// than silently falling back to `generation`/`clearGeneration`
        /// alone, since a read failure here means this instance cannot
        /// prove no other instance/process cleared the cache immediately
        /// before this token was issued. Deliberately not part of `==`/
        /// `<`'s identity comparison, for the identical reason
        /// `clearGeneration` is not: two copies of the same issued token
        /// always agree on this by construction, and it is compared
        /// separately, against a *freshly re-read* current value, by
        /// every authority check.
        var durableClearEpoch: Int?
        /// This key's durable, cross-instance/cross-process issuance
        /// ticket (``AssetDiskCache/issueTicketLocked(for:)``'s return
        /// value) reserved at the moment this token was issued (see
        /// ``AssetDiskCache/beginIssuance(for:)`` and
        /// `AssetDiskCache+WriteGeneration.swift`'s type-level doc
        /// comment) — `nil` only if that durable reservation itself
        /// failed at issuance time, which ``AssetDiskCache/acceptToken(_:for:)``
        /// treats as permanently unacceptable (fail closed), never a
        /// silent "no other write has ever happened for this key"
        /// default. This is the disk-durable, cross-process half of the
        /// per-key compare-and-swap: unlike `generation`/`clearGeneration`
        /// /`durableClearEpoch` (all whole-cache concerns),
        /// `AssetDiskCache` compares this globally-ordered issuance
        /// ticket against the *currently applied* on-disk ticket for this
        /// exact key (``AssetDiskCache/currentAppliedTicketLocked(for:)``),
        /// independent of and in addition to any other instance/process's
        /// own in-memory bookkeeping, which is what actually makes two
        /// independently wired instances/processes sharing one disk
        /// directory agree on write ordering for the same key.
        /// Deliberately not part of `==`/`<`'s identity comparison, for
        /// the identical reason `clearGeneration`/`durableClearEpoch` are
        /// not.
        var diskWriteGeneration: Int?

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
    /// eventually mutate state. Never itself durably reads
    /// ``currentDurableClearEpoch()`` (see that method's doc comment):
    /// this stays a plain, synchronous, in-memory-only operation
    /// specifically so it can run inside an atomic "check the coalescing
    /// dictionary, else create and insert" section (``coalescedFetch(key:cacheKey:candidates:)``,
    /// ``resolveRevalidationFetchID(expectedFormat:existing:slot:preIssuedAuthority:)``)
    /// without introducing a suspension point that would let two
    /// concurrent callers for the same key both observe "nothing in
    /// flight yet" and each start their own independent, uncoalesced
    /// fetch/revalidation.
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

    /// A single, atomic, cross-instance/cross-process issuance snapshot
    /// for `key`, combining the durable clear epoch and this key's own
    /// durable disk write generation (see
    /// ``AssetDiskCache/beginIssuance(for:)``) — read together, under one
    /// exclusive-lock acquisition on the disk cache, so both halves of a
    /// freshly issued ``CacheToken`` reflect exactly the same moment in
    /// time. `nil` on either field means that durable read itself failed;
    /// a caller never falls back to any other value for it (see
    /// ``isAuthoritative(_:for:)``/``AssetDiskCache/acceptToken(_:for:)``,
    /// which both fail closed on `nil`).
    struct PreIssuedAuthority: Sendable {
        let clearEpoch: Int?
        let diskWriteGeneration: Int?
    }

    /// Reads the current durable, cross-instance/cross-process clear
    /// epoch for this cache's shared directory (see
    /// `SecureCacheDirectory+ClearEpoch.swift`'s type-level doc comment),
    /// or `nil` if that durable read itself failed. `nil` is deliberately
    /// never treated as "no clear has happened" by any caller —
    /// ``isAuthoritative(_:for:)`` and ``unchanged(since:for:)``/
    /// ``clearStateUnchanged(since:for:)`` all fail closed (report "not
    /// authoritative"/"changed") the instant either the value they
    /// captured earlier, or the value they freshly re-read now, is `nil`
    /// — an inability to durably prove no cross-instance clear happened
    /// must never be silently treated as proof that none did.
    ///
    /// This method alone (unlike ``beginIssuance(for:)`` below) is safe
    /// to call repeatedly, at any point, purely to *re-check* a
    /// previously captured value — it is what every post-suspension
    /// authority re-check (``isAuthoritative(_:for:)``,
    /// ``unchanged(since:for:)``, ``memoryEntryStillCurrent(_:)``, and
    /// friends) uses. It must never itself be used to *capture* the
    /// value a fresh token is stamped with at issuance time; use
    /// ``beginIssuance(for:)`` for that instead (see its own doc comment
    /// for why the two are not interchangeable).
    func currentDurableClearEpoch() async -> Int? {
        try? await diskCache.currentClearEpoch()
    }

    /// Captures both halves of a fresh token's durable authority — the
    /// cross-instance clear epoch and this key's own durable disk write
    /// generation — together, in one disk-cache round trip, and returns
    /// `nil` for either field the underlying read failed to confirm.
    ///
    /// Called exactly once, as the very first step of issuing a fresh
    /// (never coalesced-into) fetch/revalidation/disk-hit operation,
    /// *before* the synchronous "check the coalescing dictionary, else
    /// create and issue" decision that follows it
    /// (``coalescedFetch(key:cacheKey:candidates:)``,
    /// ``resolveRevalidationFetchID(expectedFormat:existing:slot:preIssuedAuthority:)``,
    /// and the two disk-hit branches that are not behind any coalescing
    /// dictionary at all) — never afterward, and never restamped later
    /// from a value re-read after some unrelated suspension. This is
    /// exactly the fix for a prior review's "durable epoch captured
    /// after operation issuance" finding: previously, a token was issued
    /// synchronously first and only stamped with its durable epoch
    /// afterward, inside the `Task` that would go on to perform the
    /// operation's actual suspending work — a window during which a
    /// cross-instance clear (or a competing write for the same key)
    /// could land and never be observed as having preceded this
    /// operation's own issuance. Reading this snapshot *before* the
    /// join-or-create decision closes that window entirely: if this call
    /// ends up *joining* already in-flight work, the freshly captured
    /// snapshot here is simply discarded (the in-flight work's own token,
    /// captured when *it* was issued, already governs); if it *creates*
    /// fresh work, the snapshot is stamped onto the new token
    /// synchronously, with no further `await` between "decide to create"
    /// and "token is fully stamped" — see ``issueToken(for:)``'s own doc
    /// comment for why that synchronous atomicity matters.
    ///
    /// Never itself called from inside that atomic join-or-create
    /// section (it is `async` and must complete before that section
    /// begins), and never used merely to *re-check* an already-issued
    /// token's continued validity — see ``currentDurableClearEpoch()``'s
    /// doc comment for that distinction.
    func beginIssuance(for key: AssetCacheKey) async -> PreIssuedAuthority {
        guard let snapshot = try? await diskCache.beginIssuance(for: key) else {
            return PreIssuedAuthority(clearEpoch: nil, diskWriteGeneration: nil)
        }
        return PreIssuedAuthority(
            clearEpoch: snapshot.clearEpoch,
            diskWriteGeneration: snapshot.writeGeneration
        )
    }

    /// *issued* token for `key`, under the current global generation, and
    /// `key` has not been individually invalidated since `token` was
    /// issued — the compare half of every mutating call site's
    /// compare-and-swap. An operation issued before another one for the
    /// same key can never pass this check again once the later one has
    /// been issued (nor after `key` is individually invalidated or the
    /// whole cache is cleared), regardless of which one's network round
    /// trip or decode happens to finish first.
    ///
    /// Also requires `token`'s ``CacheToken/durableClearEpoch`` (stamped
    /// by ``beginIssuance(for:)`` at issuance time) to still exactly match a
    /// freshly re-read ``currentDurableClearEpoch()`` — the durable,
    /// cross-instance/cross-process half of this same compare-and-swap:
    /// a `nil` on either side (an unstamped token, or a durable read
    /// failure just now) fails closed rather than silently falling back
    /// to only this instance's own in-process `generation`/
    /// `clearGeneration` counters, which another instance/process
    /// sharing this same directory never bumps.
    func isAuthoritative(_ token: CacheToken, for key: AssetCacheKey) async -> Bool {
        guard
            token.generation == globalGeneration,
            keyLatestToken[key] == token,
            token.clearGeneration == (keyClearGeneration[key] ?? 0)
        else {
            return false
        }
        guard
            let tokenEpoch = token.durableClearEpoch,
            let currentEpoch = await currentDurableClearEpoch()
        else {
            return false
        }
        return tokenEpoch == currentEpoch
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
