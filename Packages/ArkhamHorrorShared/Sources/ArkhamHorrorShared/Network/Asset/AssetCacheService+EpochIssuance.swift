import Foundation

/// Fresh-authority issuance and post-suspension authority re-check
/// helpers for ``AssetCacheService``, split out of
/// `AssetCacheService+Epoch.swift` purely to keep that file within
/// this package's `file_length` limit -- these two files together
/// implement one cohesive per-key issuance-order authority
/// subsystem; this half owns capturing fresh durable authority at
/// issuance time and re-checking a previously captured token
/// against current durable reality.
extension AssetCacheService {
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

    /// Reads `key`'s current durable, cross-instance/cross-process
    /// *applied* ticket — the highest ticket any mutation for `key` has
    /// actually committed to disk — or `nil` if that durable read itself
    /// failed. See ``AssetDiskCache/currentAppliedTicket(for:)``'s doc
    /// comment for why this exists alongside ``currentDurableClearEpoch()``
    /// rather than being folded into it: the clear epoch alone can never
    /// detect a sibling service/process publishing a newer per-key
    /// generation without any accompanying whole-cache clear.
    func currentDurableAppliedTicket(for key: AssetCacheKey) async -> Int? {
        try? await diskCache.currentAppliedTicket(for: key)
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
    /// ``resolveOrIssueRevalidation(expectedFormat:existing:slot:)``,
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

    /// The revalidation counterpart to ``beginIssuance(for:)`` — see
    /// ``AssetDiskCache/beginRevalidationIssuance(for:expectedClearEpoch:expectedAppliedTicket:)``
    /// for the full reasoning. `historicalClearEpoch`/
    /// `historicalWriteGeneration` are the cached entry's own historical
    /// publication stamp; a `nil` return means either that durable read
    /// itself failed, *or* that stamp no longer matches durable reality
    /// (this entry has been superseded by a clear or a competing write
    /// since it was last confirmed good) — callers must treat both
    /// identically: fall through to a full, uncached fetch rather than
    /// revalidating this entry. A non-`nil` return always carries a
    /// freshly, uniquely reserved ticket for `key`, exactly like
    /// ``beginIssuance(for:)``'s own result — never the historical value
    /// verbatim.
    func beginRevalidationIssuance(
        for key: AssetCacheKey,
        historicalClearEpoch: Int,
        historicalWriteGeneration: Int
    ) async -> PreIssuedAuthority? {
        guard let snapshot = try? await diskCache.beginRevalidationIssuance(
            for: key,
            expectedClearEpoch: historicalClearEpoch,
            expectedAppliedTicket: historicalWriteGeneration
        ) else {
            return nil
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
    ///
    /// Deliberately reads the durable epoch *first*, before touching any
    /// of this actor's own synchronous, in-memory state, and performs
    /// every synchronous check as one terminal block with no further
    /// `await` between it and `return`. A prior review correctly flagged
    /// the opposite ordering (synchronous checks first, durable epoch
    /// read last) as unsound: this actor is re-entrant across `await`
    /// points, so a newer token for `key` — issued by another operation,
    /// or invalidated wholesale by a fresh ``evictAll()`` — can land
    /// *during* the epoch read; checking the synchronous state only
    /// *before* that suspension would silently miss exactly that case
    /// and report an already-superseded token as still authoritative.
    /// Reading the (only) suspending step first, then deciding
    /// everything else atomically afterward, closes that window.
    func isAuthoritative(_ token: CacheToken, for key: AssetCacheKey) async -> Bool {
        let currentEpoch = await currentDurableClearEpoch()
        guard
            token.generation == globalGeneration,
            keyLatestToken[key] == token,
            token.clearGeneration == (keyClearGeneration[key] ?? 0),
            let tokenEpoch = token.durableClearEpoch,
            let currentEpoch,
            tokenEpoch == currentEpoch
        else {
            return false
        }
        return true
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
