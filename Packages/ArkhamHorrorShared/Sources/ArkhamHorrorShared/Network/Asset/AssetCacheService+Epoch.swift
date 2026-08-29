import Foundation

/// The unified mutation-epoch authority shared by every cache-mutating
/// operation on ``AssetCacheService``: a normal fetch's eventual publish
/// (``AssetCacheService/asset(for:)``), a revalidation's eventual
/// 404/304/200 outcome (``AssetCacheService/performRevalidation(_:)``),
/// and ``AssetCacheService/evictAll()``. Split out of
/// `AssetCacheService.swift`/`AssetCacheService+Revalidation.swift` purely
/// to keep those files within this package's `file_length` convention.
///
/// Every one of those operations suspends at least once (a network round
/// trip; for a disk hit, a disk-cache actor hop and a full platform
/// decode) between the moment it starts and the moment it would mutate
/// shared cache state. Without a single authority, two overlapping
/// operations for the same key can complete out of *issuance* order
/// (whichever suspends longer finishes later) and the *later-completing*
/// one — not the more authoritative one — would win simply by finishing
/// last. This type instead makes every terminal, cache-mutating outcome
/// re-prove, immediately before it mutates anything, that no more
/// authoritative operation for the same key (or a cache-wide
/// invalidation) has already concluded since this one captured its own
/// epoch — a compare-and-swap on top of two plain counters:
///
/// - ``AssetCacheService/keyEpoch``: bumped by every terminal outcome for
///   one specific key (a definitive 404, a 304 touch, or a fresh publish).
/// - ``AssetCacheService/globalEpoch``: bumped once by
///   ``AssetCacheService/evictAll()``, which invalidates every currently
///   captured epoch — including keys not yet present in `keyEpoch` at
///   all — without needing to enumerate every key that might have an
///   operation in flight.
///
/// A `CacheEpoch` is captured once, synchronously, at the moment an
/// operation is *issued* (never re-captured later), and checked via
/// ``AssetCacheService/isCurrentEpoch(_:for:)`` immediately before every
/// point that operation is about to touch memory/disk state — including
/// again after a further suspension, if one occurs between two such
/// checks. A 404, a 304, and a fresh 200 are all gated identically: none
/// of them is treated as unconditionally authoritative regardless of
/// timing, because a *stale* 404 (a slow response to an old request,
/// completing after a newer request already published fresh content) is
/// just as capable of wrongly resurrecting/destroying state as a stale
/// 304 or 200 would be.
extension AssetCacheService {
    /// A snapshot of both mutation-epoch counters, captured at the moment
    /// one specific cache-mutating operation was issued.
    struct CacheEpoch: Equatable, Sendable {
        let global: Int
        let key: Int
    }

    /// This key's current epoch, right now. Callers issuing a fresh
    /// (never coalesced-into) operation capture this exactly once, before
    /// creating the `Task` that will eventually mutate state.
    func currentEpoch(for key: AssetCacheKey) -> CacheEpoch {
        CacheEpoch(global: globalEpoch, key: keyEpoch[key, default: 0])
    }

    /// `true` only if neither counter has moved since `epoch` was
    /// captured — the compare half of every mutating call site's
    /// compare-and-swap. A caller that gets `false` back must not touch
    /// memory/disk state for `key` at all; a more authoritative operation
    /// (or a full `evictAll()`) already superseded it.
    func isCurrentEpoch(_ epoch: CacheEpoch, for key: AssetCacheKey) -> Bool {
        epoch.global == globalEpoch && epoch.key == keyEpoch[key, default: 0]
    }

    /// Advances `key`'s own epoch. Called by every terminal, per-key
    /// mutating outcome (404 eviction, 304 touch, fresh publish) exactly
    /// once, immediately after (never before) that outcome's own
    /// `isCurrentEpoch` check has already passed — the swap half of the
    /// compare-and-swap.
    func bumpKeyEpoch(_ key: AssetCacheKey) {
        keyEpoch[key, default: 0] += 1
    }
}
