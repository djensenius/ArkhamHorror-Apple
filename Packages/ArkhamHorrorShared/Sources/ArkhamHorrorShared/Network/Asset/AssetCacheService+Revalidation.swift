import Foundation

/// Conditional-revalidation subsystem for ``AssetCacheService``: re-checking
/// an on-disk hit against the current validation contract, and the
/// generation-gated ETag/Last-Modified revalidation path used when a
/// caller explicitly asks to revalidate an already-cached entry. Split
/// out of `AssetCacheService.swift` purely to keep each file within this
/// package's file/type-length conventions; still part of the single
/// `AssetCacheService` actor's isolated state.
extension AssetCacheService {
    /// Conditionally revalidates an already-cached entry for `key` against
    /// the exact URL its payload came from. Requires a currently valid
    /// cached entry (memory or disk) to condition against; if none exists,
    /// throws ``AssetError/staleConditionalResponse`` immediately without
    /// making any network call, since there is nothing to pair a 304 with.
    ///
    /// The persisted URL is also required to exactly match one of `key`'s
    /// own current resolved candidates (never trusted as-is), so tampered
    /// or corrupted on-disk metadata cannot redirect a revalidation request
    /// to an unexpected host or path.
    ///
    /// Also requires the cached entry to actually carry a validator
    /// (`ETag` or `Last-Modified`): a 304 is only meaningful in response to
    /// a genuinely conditional request, so without either validator this
    /// throws the same typed error immediately rather than sending an
    /// unconditional request that a non-conforming server could still
    /// answer with a 304 we would otherwise wrongly accept as "unchanged".
    ///
    /// Concurrent revalidations for the same cache key, URL, and validator
    /// snapshot (`ETag`/`Last-Modified`) are coalesced onto a single
    /// network round trip exactly like ``asset(for:)``'s candidate-walk
    /// fetch (see
    /// ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:preIssuedAuthority:)``).
    /// A per-key generation counter additionally guards every terminal
    /// outcome so that a delayed completion can never resurrect or
    /// overwrite state a more authoritative (logically newer) revalidation
    /// already concluded while this one was still in flight.
    func revalidate(for key: AssetKey) async throws -> CachedAsset {
        let candidates = try resolvedCandidates(for: key)
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)

        // Snapshotted *before* the memory-cache read itself: without
        // this, a memory hit whose bytes were already superseded by a
        // concurrent `invalidate`/`evictAll` (which can run to completion
        // on *this* actor while this call is suspended inside
        // `memoryCache.get`, since that is a genuine hop to a different
        // actor) would still be handed to `revalidateExisting` below,
        // which unconditionally mints a *fresh* authoritative token for
        // this key from those already-superseded bytes — resurrecting
        // exactly the state the concurrent invalidation just cleared the
        // moment a 304 response arrives for it.
        //
        // Uses the narrower ``snapshotClearState(for:)``/
        // ``clearStateUnchanged(since:for:)`` pair rather than the
        // broader ``snapshotAuthority(for:)``/``unchanged(since:for:)``
        // one: this branch's own subsequent call below is coalesced
        // through ``coalescedRevalidation(existing:key:cacheKey:candidates:)``,
        // so a second, concurrent, otherwise-identical `revalidate(for:)`
        // call legitimately observes `keyLatestToken` change the instant
        // the first call's coalesced revalidation issues its shared
        // token — that is the intended coalescing outcome, not
        // staleness, and must not defeat this memory hit. See
        // ``snapshotClearState(for:)``'s doc comment. Wrapped in an
        // authority window (``beginAuthorityWindow(for:)``) so this key's
        // bookkeeping cannot be pruned out from under this still-suspended
        // snapshot purely due to unrelated keys' churn.
        beginAuthorityWindow(for: cacheKey)
        let memorySnapshot = await snapshotClearState(for: cacheKey)
        let memoryHit = await memoryCache.get(cacheKey)
        var memoryHitIsCurrent = false
        if let memoryHit {
            let stillUnchanged = await clearStateUnchanged(since: memorySnapshot, for: cacheKey)
            let stillCurrentEpoch = await memoryEntryStillCurrent(
                memoryHit.durableClearEpoch,
                storedGeneration: memoryHit.writeGeneration,
                for: cacheKey
            )
            memoryHitIsCurrent = stillUnchanged && stillCurrentEpoch
        }
        endAuthorityWindow(for: cacheKey)
        if let existing = memoryHit, memoryHitIsCurrent {
            // This entry's own *historical* publication stamp
            // (``AssetMemoryCache/CachedAsset/durableClearEpoch``/
            // ``AssetMemoryCache/CachedAsset/writeGeneration``, fixed at
            // the moment this exact memory entry was published or last
            // successfully revalidated) is validated -- atomically,
            // under this key's decision lock and one disk-cache lock
            // hold, alongside reserving this operation's own fresh
            // authority -- entirely inside
            // ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:preIssuedAuthority:)``,
            // never eagerly at this call site (a prior revision of this
            // code called
            // ``beginRevalidationIssuance(for:historicalClearEpoch:historicalWriteGeneration:)``
            // unconditionally here, before knowing whether this call
            // would join already in-flight work or start fresh work --
            // wasting a disk-ticket reservation, and under this
            // subsystem's per-key issuance-ordered authority, wastefully
            // fencing out the ticket the joined operation actually
            // relies on, whenever it turned out to join). A missing
            // historical stamp, a durable read failure, or the entry's
            // own historical stamp no longer matching current durable
            // reality all surface identically, from inside that call, as
            // ``AssetError/revalidationProvenanceUnavailable`` -- caught
            // here and treated exactly like a genuine miss: fall through
            // to the disk/fetch path below rather than ever revalidating
            // untrustworthy provenance. Mirrors the disk-hit branch
            // below, which does the identical check for the identical
            // reason.
            do {
                return try await revalidateExisting(
                    existing,
                    key: key,
                    cacheKey: cacheKey,
                    candidates: candidates
                )
            } catch AssetError.revalidationProvenanceUnavailable {
                return try await revalidateFromDiskOrFetch(
                    key: key, cacheKey: cacheKey, candidates: candidates
                )
            }
        }
        return try await revalidateFromDiskOrFetch(
            key: key, cacheKey: cacheKey, candidates: candidates
        )
    }

    /// Resolves the exact `(url, format)` pair to issue a conditional
    /// revalidation request against for `existing`, cross-checked against
    /// `candidates`. Shared by ``revalidateExisting(_:key:cacheKey:candidates:)``
    /// (which treats a missing validator/URL as
    /// ``AssetError/staleConditionalResponse``, since its caller
    /// explicitly asked to revalidate) and ``asset(for:)``'s disk-hit
    /// branch (which instead tolerates a missing validator by falling
    /// through to an ordinary unconditional fetch, since that API's
    /// contract is simply "give me a currently valid asset", not
    /// "revalidate this specific one").
    ///
    /// The persisted `resolvedURLString` is untrusted input (on-disk
    /// metadata could be corrupted or tampered while still decoding and
    /// passing the hash/size checks in `AssetDiskCache.get`): only ever
    /// resolves to a URL that exactly matches one of `key`'s own current
    /// candidates, never whatever URL happens to be recorded, so tampered
    /// metadata cannot redirect a request to an unexpected host or path.
    /// Looking up the matching candidate itself (rather than only
    /// checking membership in a set of URL strings) is also what recovers
    /// the exact ``AssetFormat`` that candidate resolved to: candidates
    /// for the same key are not all guaranteed to share one format, so
    /// `key.expectedFormat` alone is not a safe stand-in for validating a
    /// fresh revalidation response.
    ///
    /// Also recovers `candidateIndex` — this candidate's position within
    /// `candidates` — so a caller (``asset(for:)``'s disk-hit branch) that
    /// receives an authoritative, successfully-invalidated 404 for
    /// exactly this resolved candidate can resume an ordinary candidate
    /// walk starting immediately *after* it, rather than treating a
    /// single dead candidate as if the entire chain (including any
    /// English/alternate-front fallback candidates that were never even
    /// requested) were exhausted.
    struct ConditionalRevalidationTarget {
        let url: URL
        let format: AssetFormat
        let candidateIndex: Int
    }

    func conditionalRevalidationTarget(
        for existing: CachedAsset,
        key: AssetKey,
        candidates: [AssetCandidate]
    ) -> ConditionalRevalidationTarget? {
        guard
            let url = URL(string: existing.metadata.resolvedURLString),
            let matchedIndex = candidates.firstIndex(where: {
                $0.url(base: key.source).absoluteString == existing.metadata.resolvedURLString
            }),
            existing.metadata.etag != nil || existing.metadata.lastModified != nil
        else {
            return nil
        }
        return ConditionalRevalidationTarget(
            url: url,
            format: candidates[matchedIndex].format,
            candidateIndex: matchedIndex
        )
    }

    /// Validates `existing` (already confirmed current/valid by the
    /// caller) against `key`'s own resolved candidates and issues the
    /// actual conditional revalidation. Split out of ``revalidate(for:)``
    /// purely so that function can share this exact tail between its
    /// memory-hit and validated-disk-hit branches; widened from `private`
    /// to `internal` since the latter branch now lives in the sibling
    /// file `AssetCacheService+RevalidationDiskFetch.swift`.
    ///
    /// `preIssuedAuthority`, when non-`nil`, is a durable clear-epoch/
    /// disk-write-generation snapshot the caller has *already* validated
    /// and reserved itself, for its own independent purpose, *before*
    /// calling this — passed straight through to
    /// ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:preIssuedAuthority:)``
    /// unchanged, never re-derived from `existing` a second time. `nil`
    /// (the plain memory-hit branch's own call) instead lets that method
    /// derive and validate authority fresh from `existing`'s own
    /// historical stamp itself, atomically under this key's decision
    /// lock, only if and when it actually starts fresh work — see that
    /// method's doc comment for the full reasoning (this is the fix for
    /// a prior revision, where the memory-hit branch read/reserved
    /// authority *before* calling this, unconditionally — discarding the
    /// result whenever this call ended up joining already in-flight work
    /// instead, which wasted a disk-ticket reservation that could
    /// permanently fence out the ticket the joined operation actually
    /// relies on).
    func revalidateExisting(
        _ existing: CachedAsset,
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate],
        preIssuedAuthority: PreIssuedAuthority? = nil
    ) async throws -> CachedAsset {
        guard let target = conditionalRevalidationTarget(
            for: existing,
            key: key,
            candidates: candidates
        ) else {
            throw AssetError.staleConditionalResponse
        }
        return try await coalescedRevalidation(
            cacheKey: cacheKey,
            url: target.url,
            expectedFormat: target.format,
            existing: existing,
            preIssuedAuthority: preIssuedAuthority
        )
    }

    /// The fetch identity and authoritative token a caller of
    /// ``resolveOrIssueRevalidation(expectedFormat:existing:slot:preIssuedAuthority:)``
    /// must use for its own subsequent waiter registration and final
    /// delivery liveness re-check — a dedicated, non-tuple type purely to
    /// keep this package's `large_tuple` lint convention satisfied.
    struct ResolvedRevalidationFetch {
        let id: UUID
        let token: CacheToken
    }

    /// Returns the identity and authoritative token of the in-flight
    /// revalidation `slot` should join: either an already-registered
    /// fetch's own (issued when *it* started), or a freshly-started one's
    /// (minted here, for this call, only after `existing`'s own
    /// historical publication stamp has just been re-validated against
    /// current durable reality *and* fresh disk authority reserved for
    /// it — see
    /// ``beginRevalidationIssuance(for:historicalClearEpoch:historicalWriteGeneration:)``).
    /// Split out of
    /// ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:preIssuedAuthority:)``
    /// purely to keep that function's body within this package's
    /// `function_body_length` limit.
    ///
    /// Called only while ``AssetCacheService/acquireIssuanceDecisionLock(for:)``
    /// is held for `slot.cacheKey` (see
    /// `AssetCacheService+IssuanceDecisionLock.swift`): this is what
    /// guarantees the join-or-create check on the very first line below,
    /// and — on the "create" branch, when `preIssuedAuthority` is `nil` —
    /// the provenance check and fresh disk-authority reservation that
    /// follows it, all happen as one atomic unit with no other concurrent
    /// caller for this exact key able to interleave a redundant
    /// reservation of its own in between. When a fetch is already
    /// registered for `slot`, this simply joins it: the in-flight fetch's
    /// own token, issued and stamped when *it* started, already governs
    /// this shared operation's authority for every one of its waiters
    /// uniformly, and neither `existing`'s provenance nor
    /// `preIssuedAuthority` is ever even consulted on that branch.
    ///
    /// On the "create" branch, `preIssuedAuthority` (when non-`nil`) is
    /// used directly, exactly as a prior revision of this code always
    /// did — see
    /// ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:preIssuedAuthority:)``'s
    /// doc comment for why the validated-disk-hit callers that supply it
    /// must never have it re-derived from `existing` here instead. When
    /// `preIssuedAuthority` is `nil` (the bare memory-hit branch), this
    /// derives and validates it fresh from `existing`'s own historical
    /// stamp, atomically alongside the reservation itself, and throws
    /// ``AssetError/revalidationProvenanceUnavailable`` when `existing`
    /// carries no historical stamp at all, or its own
    /// ``beginRevalidationIssuance(for:historicalClearEpoch:historicalWriteGeneration:)``
    /// itself reports that stamp no longer matches current durable
    /// reality (or that durable read outright failed) — see that error
    /// case's own doc comment for why the one caller that can reach this
    /// branch must catch it and fall back to an uncached path, never
    /// surfacing it further.
    func resolveOrIssueRevalidation(
        expectedFormat: AssetFormat,
        existing: CachedAsset,
        slot: RevalidationSlot,
        preIssuedAuthority: PreIssuedAuthority?
    ) async throws -> ResolvedRevalidationFetch {
        if let current = inFlightRevalidation[slot] {
            return ResolvedRevalidationFetch(id: current.id, token: current.token)
        }
        let authority: PreIssuedAuthority
        if let preIssuedAuthority {
            authority = preIssuedAuthority
        } else {
            guard
                let historicalEpoch = existing.durableClearEpoch,
                let historicalGeneration = existing.writeGeneration,
                let resolvedAuthority = await beginRevalidationIssuance(
                    for: slot.cacheKey,
                    historicalClearEpoch: historicalEpoch,
                    historicalWriteGeneration: historicalGeneration
                )
            else {
                throw AssetError.revalidationProvenanceUnavailable
            }
            authority = resolvedAuthority
        }
        var token = issueToken(for: slot.cacheKey)
        token.durableClearEpoch = authority.clearEpoch
        token.diskWriteGeneration = authority.diskWriteGeneration
        let revalidationRequest = RevalidationRequest(
            cacheKey: slot.cacheKey,
            url: slot.url,
            expectedFormat: expectedFormat,
            existing: existing,
            etag: slot.etag,
            lastModified: slot.lastModified,
            token: token
        )
        let newTask = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await performRevalidation(revalidationRequest)
        }
        let newFetch = RevalidationFetch(task: newTask, token: token)
        setInFlightRevalidation(newFetch, for: slot)
        let fetchID = newFetch.id
        Task { [weak self] in
            let result = await newTask.result
            await self?.completeRevalidation(slot, fetchID: fetchID, result: result)
        }
        return ResolvedRevalidationFetch(id: fetchID, token: token)
    }
}
