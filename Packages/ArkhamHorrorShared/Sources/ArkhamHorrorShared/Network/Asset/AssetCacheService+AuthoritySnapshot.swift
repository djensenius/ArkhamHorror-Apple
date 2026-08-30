import Foundation

/// Read-only authority snapshot/compare helpers for `AssetCacheService`,
/// split out of `AssetCacheService+Epoch.swift` purely to keep that file
/// within this package's `file_length` convention.
extension AssetCacheService {
    /// A named, non-tuple result type for ``snapshotAuthority(for:)`` /
    /// ``unchanged(since:for:)`` — a plain 3-member tuple would trip this
    /// package's `large_tuple` lint convention, and a named type also
    /// documents each field's role once instead of relying on positional
    /// tuple-label repetition at every call site.
    struct AuthoritySnapshot: Equatable {
        let token: CacheToken?
        let generation: Int
        let clearGeneration: Int
        /// The durable, cross-instance/cross-process
        /// ``currentDurableClearEpoch()`` value observed at snapshot
        /// time — see ``unchanged(since:for:)``'s doc comment for why a
        /// `nil` here (a durable read failure at snapshot time) can never
        /// later compare equal to anything, including a second `nil`.
        let durableClearEpoch: Int?
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
    ///
    /// Includes ``AssetCacheService/keyClearGeneration`` alongside
    /// `keyLatestToken`/`globalGeneration`: a single unified snapshot/
    /// compare pair used by *every* caller (an ordinary memory/disk hit
    /// and a revalidation's memory-hit branch alike), rather than two
    /// separate, subtly different checks — a design that previously let
    /// some callers miss an intervening invalidation entirely (see
    /// ``isAuthoritative(_:for:)``'s doc comment).
    ///
    /// Also includes ``currentDurableClearEpoch()``, read fresh here:
    /// without this, an entry already cached in *this* instance's own
    /// memory before a *different* instance/process sharing this same
    /// directory ran its own `evictAll()` would still be reported
    /// "unchanged" by every one of this instance's own in-process
    /// counters (which that other instance's clear never touches), and
    /// would go on being served indefinitely — the exact cross-instance
    /// gap a purely in-process authority model cannot close. `async`
    /// purely for this one additional durable read; safe to call from
    /// any context already able to suspend (this is never itself
    /// performed inside an atomic "check the coalescing dictionary, else
    /// create and insert" section — see ``issueToken(for:)``'s doc
    /// comment for the one place that distinction does matter).
    func snapshotAuthority(for key: AssetCacheKey) async -> AuthoritySnapshot {
        await AuthoritySnapshot(
            token: keyLatestToken[key],
            generation: globalGeneration,
            clearGeneration: keyClearGeneration[key] ?? 0,
            durableClearEpoch: currentDurableClearEpoch()
        )
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
    ///
    /// Also fails (reports "changed") if either `snapshot.durableClearEpoch`
    /// or a freshly re-read ``currentDurableClearEpoch()`` is `nil` — a
    /// durable read failure, at either end, must never be silently
    /// treated as "no cross-instance clear happened", the same fail-closed
    /// reasoning ``isAuthoritative(_:for:)`` applies to its own token's
    /// ``CacheToken/durableClearEpoch``.
    func unchanged(
        since snapshot: AuthoritySnapshot,
        for key: AssetCacheKey
    ) async -> Bool {
        guard
            keyLatestToken[key] == snapshot.token,
            globalGeneration == snapshot.generation,
            (keyClearGeneration[key] ?? 0) == snapshot.clearGeneration
        else {
            return false
        }
        guard
            let snapshotEpoch = snapshot.durableClearEpoch,
            let currentEpoch = await currentDurableClearEpoch()
        else {
            return false
        }
        return snapshotEpoch == currentEpoch
    }

    /// `true` only if `storedEpoch` — a ``CachedAsset/durableClearEpoch``
    /// captured at the moment some prior call published or revalidated
    /// this exact memory entry — still exactly matches a *freshly re-read*
    /// ``currentDurableClearEpoch()``. `false` if either value is `nil`
    /// (an unstamped entry, or a durable read failure just now — both
    /// fail closed, the same reasoning ``isAuthoritative(_:for:)`` and
    /// ``unchanged(since:for:)`` already apply to their own durable-epoch
    /// comparisons) or if they simply differ.
    ///
    /// Deliberately *additive* to, not a replacement for, the existing
    /// ``unchanged(since:for:)``/``clearStateUnchanged(since:for:)``
    /// snapshot-then-recheck pairs already guarding every memory hit:
    /// those two remain exactly correct for the race they were built to
    /// catch (an invalidation/clear that happens *during* this specific
    /// call's own suspension window, between their own snapshot and
    /// recheck reads). What neither of them can ever detect is a clear
    /// that already completed *before* this call even began — both of
    /// their reads would then trivially observe the same
    /// already-superseded epoch and agree "unchanged", even though the
    /// cached entry itself was published under a durable epoch that
    /// predates that clear. Comparing the entry's own *stored* epoch
    /// (fixed at the moment it was written) against a fresh read here,
    /// on every hit, closes exactly that gap: a memory entry published
    /// under epoch *N* can never again pass this check once any
    /// instance/process sharing this cache's directory has since bumped
    /// the durable epoch past *N*, regardless of how long ago that
    /// publish happened or whether this specific call has been suspended
    /// at all.
    func memoryEntryStillCurrent(_ storedEpoch: Int?) async -> Bool {
        guard
            let storedEpoch,
            let currentEpoch = await currentDurableClearEpoch()
        else {
            return false
        }
        return storedEpoch == currentEpoch
    }

    /// A named, non-tuple result type for ``snapshotClearState(for:)``/
    /// ``clearStateUnchanged(since:for:)`` — see ``AuthoritySnapshot``'s
    /// own doc comment for why a plain tuple is avoided here too, now
    /// that this pair also carries a third (durable-epoch) field.
    struct ClearStateSnapshot: Equatable {
        let generation: Int
        let clearGeneration: Int
        let durableClearEpoch: Int?
    }

    /// A narrower read-only snapshot of `key`'s *invalidation* state only
    /// — the whole-cache generation, this key's own clear generation, and
    /// the durable cross-instance clear epoch — deliberately omitting
    /// ``AssetCacheService/keyLatestToken``.
    ///
    /// Used exclusively by ``revalidate(for:)``'s memory-hit branch: that
    /// branch's own subsequent call into ``revalidateExisting(_:key:cacheKey:candidates:)``
    /// is coalesced through ``coalescedRevalidation(existing:key:cacheKey:candidates:)``'s
    /// in-flight dictionary, so a second, concurrent, otherwise-identical
    /// `revalidate(for:)` call for the very same key legitimately
    /// observes a *different* ``keyLatestToken`` the moment the first
    /// call's own coalesced revalidation has issued its shared token —
    /// that is the intended coalescing outcome, not staleness, and must
    /// not itself defeat the second call's memory hit. What *would*
    /// genuinely invalidate this memory hit is an actual clear: either an
    /// individual ``invalidate(_:token:)`` for this key (bumps
    /// ``AssetCacheService/keyClearGeneration``), a cache-wide
    /// ``evictAll()`` (bumps ``AssetCacheService/globalGeneration``), or
    /// a *different* instance/process's cache-wide clear (bumps only the
    /// durable epoch this pair also now observes) — all three of which
    /// this narrower pair still catches. Every other call site (plain
    /// memory/disk hits in ``asset(for:)``, and `revalidate(for:)`'s own
    /// disk-hit branch, neither of which is behind any coalescing
    /// dictionary) continues to use the broader
    /// ``snapshotAuthority(for:)``/``unchanged(since:for:)`` pair.
    func snapshotClearState(for key: AssetCacheKey) async -> ClearStateSnapshot {
        await ClearStateSnapshot(
            generation: globalGeneration,
            clearGeneration: keyClearGeneration[key] ?? 0,
            durableClearEpoch: currentDurableClearEpoch()
        )
    }

    /// `true` only if `key`'s *invalidation* state is exactly what
    /// ``snapshotClearState(for:)`` observed it to be — see that method's
    /// doc comment for why this intentionally ignores
    /// ``AssetCacheService/keyLatestToken`` churn from a legitimately
    /// coalescing concurrent operation for the same key, and
    /// ``unchanged(since:for:)``'s doc comment for why a `nil` durable
    /// epoch on either side always fails closed here too.
    func clearStateUnchanged(
        since snapshot: ClearStateSnapshot,
        for key: AssetCacheKey
    ) async -> Bool {
        guard
            globalGeneration == snapshot.generation,
            (keyClearGeneration[key] ?? 0) == snapshot.clearGeneration
        else {
            return false
        }
        guard
            let snapshotEpoch = snapshot.durableClearEpoch,
            let currentEpoch = await currentDurableClearEpoch()
        else {
            return false
        }
        return snapshotEpoch == currentEpoch
    }
}
