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
    /// this exact memory entry — still *exactly* matches a **single,
    /// atomically-read** ``AssetDiskCache/currentKeyAuthority(for:)``
    /// snapshot's clear epoch, **and** `storedAuthorityID` — that same
    /// entry's own ``CachedAsset/authorityID`` — still *exactly*
    /// matches that same snapshot's most-recently-*issued* ``AuthorityID``
    /// for `key`. `false` if any of `storedEpoch`/`storedAuthorityID`/the
    /// fresh durable snapshot itself is `nil` (an unstamped entry, or a
    /// durable read failure just now — both fail closed, the same
    /// reasoning ``isAuthoritative(_:for:)`` and ``unchanged(since:for:)``
    /// already apply to their own durable comparisons).
    ///
    /// **Why the per-key authority check exists at all, alongside the
    /// epoch check.** `durableClearEpoch` only ever changes on a
    /// whole-cache clear (``AssetDiskCache/removeAll()``): it can never,
    /// by itself, detect a *sibling* ``AssetCacheService``/
    /// `AssetDiskCache` instance (a second service in this process, or a
    /// second OS process) sharing this same on-disk directory publishing
    /// a genuinely *different*, newer body for this exact key under the
    /// *same* epoch — an ordinary per-key ``AssetDiskCache/set(_:payload:metadata:token:)``
    /// never bumps the epoch at all. Without this second check, service A
    /// could cache epoch-0 content in memory, service B could then
    /// publish an epoch-0-but-newer-generation replacement for the same
    /// key to disk, and A's epoch check alone would keep reporting its
    /// now-superseded memory entry "still current" forever — the exact
    /// "sibling clear leaves existing memory servable" defect a prior
    /// review flagged.
    ///
    /// **Why both fields must come from one atomically-read snapshot,
    /// never two separately-locked reads.** A prior revision called
    /// ``currentDurableClearEpoch()`` and a separate durable applied-
    /// ticket read one after another, each its own independent disk-cache
    /// lock acquisition/release — a torn read: a sibling instance/
    /// process's whole-cache clear landing in the exact window between
    /// those two calls could leave this check comparing a pre-clear epoch
    /// against a post-clear authority (or vice versa), neither half actually
    /// describing the same durable moment in time.
    /// ``AssetDiskCache/currentKeyAuthority(for:)`` instead reads both
    /// under a single lock hold, so they always describe one consistent
    /// instant.
    ///
    /// **Why equality against the most-recently-*issued* authority, not
    /// against the currently-*applied* one.** A sibling service/process
    /// can durably issue a fresh ``AuthorityID`` for this exact key the
    /// moment it begins a fetch/revalidation, strictly *before* that
    /// operation's own eventual mutation actually lands and replaces the
    /// applied disposition; during that whole window, an
    /// applied-authority-only comparison would keep reporting this memory
    /// entry "still current" even though a strictly newer,
    /// already-in-flight operation for this exact key has already been
    /// issued and may complete with entirely different content (or a
    /// definitive removal) at any moment. Comparing against the
    /// most-recently-issued identifier instead rejects this memory hit
    /// the instant *any* newer operation for this key has been issued
    /// anywhere, regardless of whether that operation has itself
    /// completed yet — the strictest safe comparison, and still exactly
    /// what a genuinely-current, untouched-since memory entry's own
    /// stamped identifier will always continue to satisfy (nothing else
    /// has ever been issued for this key since). This remains correct
    /// even for a memory-only entry whose own disk write failed
    /// non-fatally (``AssetCacheService+Publish.swift``'s documented
    /// best-effort policy): ``AssetDiskCache/beginIssuance(for:)``
    /// durably records this operation's own identifier *before* the
    /// write it gates is even attempted, so that identifier is already
    /// durably this key's most-recently-issued authority regardless of
    /// whether the later write itself actually landed.
    ///
    /// Deliberately *additive* to, not a replacement for, the existing
    /// ``unchanged(since:for:)``/``clearStateUnchanged(since:for:)``
    /// snapshot-then-recheck pairs already guarding every memory hit:
    /// those two remain exactly correct for the race they were built to
    /// catch (an invalidation/clear that happens *during* this specific
    /// call's own suspension window, between their own snapshot and
    /// recheck reads). What none of them can ever detect is a clear or a
    /// sibling per-key publish that already completed *before* this call
    /// even began — comparing the entry's own *stored* epoch/authority
    /// (fixed at the moment it was written) against a fresh read here, on
    /// every hit, closes exactly that gap.
    func memoryEntryStillCurrent(
        _ storedEpoch: Int?,
        storedAuthorityID: AuthorityID?,
        for key: AssetCacheKey
    ) async -> Bool {
        guard
            let storedEpoch,
            let storedAuthorityID,
            let currentAuthority = await currentDurableKeyAuthority(for: key)
        else {
            return false
        }
        guard !authorityIsRetiring(storedAuthorityID, epoch: storedEpoch, for: key) else {
            // `storedAuthorityID`'s own mutation has already been decided
            // to be retracted (see ``retiringGenerations``'s doc
            // comment) — even though its durable stamps still exactly
            // match current disk reality (nothing else has been issued
            // for this key since), this exact entry must never be served
            // again: the sole caller(s) who ever asked for it have
            // already been told, definitively, that it will not survive.
            return false
        }
        guard storedEpoch == currentAuthority.clearEpoch else { return false }
        return authorityGapIsEntirelyAbandoned(
            from: currentAuthority.issuedAuthorityID,
            downTo: storedAuthorityID,
            epoch: currentAuthority.clearEpoch,
            for: key
        )
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

    /// The final, synchronous, actor-isolated re-verification of `key`'s
    /// *local* authority state against `snapshot` — deliberately
    /// re-reading ``AssetCacheService/keyLatestToken``/
    /// ``AssetCacheService/globalGeneration``/
    /// ``AssetCacheService/keyClearGeneration`` fresh, right now, rather
    /// than reusing whichever ``unchanged(since:for:)``/
    /// ``clearStateUnchanged(since:for:)`` boolean a caller already
    /// computed earlier in the same lookup.
    ///
    /// **Must be called as the last step before a memory hit is used —
    /// after every durable (`await`) check that decision also depends on
    /// has already completed, with no further suspension between this
    /// call and the caller's own `return`.** ``asset(for:)``'s and
    /// ``revalidate(for:)``'s memory-hit branches each call
    /// ``unchanged(since:for:)``/``clearStateUnchanged(since:for:)`` and
    /// then ``memoryEntryStillCurrent(_:storedAuthorityID:for:)`` in
    /// sequence — both of the latter's own *internal* implementations
    /// suspend at least once more (a durable disk round trip) after the
    /// first check's own local-state comparison already ran. A same-actor
    /// invalidation (``invalidate(_:token:)``, ``evictAll()``, or a fresh
    /// issuance for this exact key) can complete *entirely* — bumping
    /// ``AssetCacheService/globalGeneration``/
    /// ``AssetCacheService/keyClearGeneration``/``keyLatestToken``
    /// synchronously, in-process — while one of those durable reads is
    /// still in flight, purely because that durable counterpart's own
    /// disk-actor round trip happened to be scheduled to run (and
    /// return) *before* the sibling invalidation's own durable commit
    /// landed. In that exact window, the earlier local-state check
    /// already passed (it ran before the invalidation happened at all)
    /// and the durable check can also still report "unchanged" (its own
    /// disk-side counterpart has not caught up yet) — but this actor's
    /// own in-process bookkeeping has, by now, already moved on. Only a
    /// final synchronous re-comparison, performed with no suspension
    /// between it and the decision it gates, is guaranteed to observe
    /// that already-landed, in-process invalidation regardless of
    /// whether its own durable counterpart has caught up yet.
    func localAuthorityStillMatchesSync(
        _ snapshot: AuthoritySnapshot,
        for key: AssetCacheKey
    ) -> Bool {
        keyLatestToken[key] == snapshot.token
            && globalGeneration == snapshot.generation
            && (keyClearGeneration[key] ?? 0) == snapshot.clearGeneration
    }

    /// The ``ClearStateSnapshot`` counterpart to
    /// ``localAuthorityStillMatchesSync(_:for:)`` — see that method's doc
    /// comment for why this final, synchronous, no-further-suspension
    /// re-check is required, and ``snapshotClearState(for:)``'s doc
    /// comment for why this pair deliberately omits `keyLatestToken`.
    func localClearStateStillMatchesSync(
        _ snapshot: ClearStateSnapshot,
        for key: AssetCacheKey
    ) -> Bool {
        globalGeneration == snapshot.generation
            && (keyClearGeneration[key] ?? 0) == snapshot.clearGeneration
    }
}
