import Foundation

/// Conditional-revalidation subsystem for ``AssetCacheService``: re-checking
/// an on-disk hit against the current validation contract, and the
/// generation-gated ETag/Last-Modified revalidation path used when a
/// caller explicitly asks to revalidate an already-cached entry. Split
/// out of `AssetCacheService.swift` purely to keep each file within this
/// package's file/type-length conventions; still part of the single
/// `AssetCacheService` actor's isolated state.
extension AssetCacheService {
    /// Re-validates an on-disk cache hit against the *current* validation
    /// contract before ever trusting it as an already-resolved asset.
    ///
    /// ``AssetDiskCache/get(_:)`` already re-verifies the payload's byte
    /// count and SHA-256 hash against its own metadata (so the bytes are
    /// exactly what was written), but that alone does not prove the
    /// payload is still a genuinely valid, fully decodable image under
    /// *this process's* current limits: limits can tighten between
    /// launches, and a previously-published entry could in principle
    /// predate a validation fix. This re-runs the full
    /// format/magic-byte/dimension validation, cross-checks the freshly
    /// parsed dimensions against what metadata claims, and performs a full
    /// platform decode — never trusting metadata's `width`/`height` alone
    /// to stand in for a real decode.
    ///
    /// Returns `nil` (having already quarantined the disk entry) on any
    /// genuine mismatch or validation/decode failure. A `CancellationError`
    /// is rethrown instead of quarantining: it means the caller stopped
    /// caring, not that the entry is invalid.
    ///
    /// The persisted `resolvedURLString` is untrusted: a disk hit is only
    /// accepted when it exactly matches one of `key`'s own current
    /// candidates (never whatever URL happens to be recorded), which also
    /// recovers the exact ``AssetFormat`` that candidate resolved to.
    func revalidateDiskHit(
        _ cached: CachedAsset,
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate],
        token: CacheToken
    ) async throws -> CachedAsset? {
        guard let candidate = candidates.first(where: {
            $0.url(base: key.source).absoluteString == cached.metadata.resolvedURLString
        }) else {
            await invalidate(cacheKey, token: token)
            return nil
        }
        do {
            let validated = try AssetImageValidator.validate(
                data: cached.payload,
                declaredContentType: cached.metadata.contentType,
                expectedFormat: candidate.format,
                limits: limits
            )
            guard
                validated.width == cached.metadata.width,
                validated.height == cached.metadata.height
            else {
                throw AssetError.malformedImageData
            }
            let decoded = try await decodeImageOffActor(cached.payload)
            guard decoded.width == validated.width, decoded.height == validated.height else {
                throw AssetError.malformedImageData
            }
            return cached
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await invalidate(cacheKey, token: token)
            return nil
        }
    }

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
    /// fetch (see ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:)``).
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
            let stillCurrentEpoch = await memoryEntryStillCurrent(memoryHit.durableClearEpoch)
            memoryHitIsCurrent = stillUnchanged && stillCurrentEpoch
        }
        endAuthorityWindow(for: cacheKey)
        if let existing = memoryHit, memoryHitIsCurrent {
            // Read here, immediately, rather than passing `nil` and
            // letting
            // ``resolveRevalidationFetchID(expectedFormat:existing:slot:preIssuedEpoch:)``
            // read one later, inside whatever `Task` body actually
            // performs the network round trip: that body only starts
            // running once its `Task` is scheduled, a genuine gap after
            // this synchronous
            // point during which a cross-instance/cross-process clear
            // could land — reading only then would capture a *post*-clear
            // epoch onto a token whose whole purpose is proving no such
            // clear happened before this revalidation was issued,
            // silently "laundering" the clear and letting a 304 paired
            // with `existing`'s pre-clear bytes sail through
            // ``performRevalidation(_:)``'s own authority check. Mirrors
            // the disk-hit branch below, which already reads immediately
            // for the identical reason.
            //
            // Deliberately just the raw epoch value, not a full
            // ``issueToken(for:)``-minted token: see
            // ``revalidateExisting(_:key:cacheKey:candidates:preIssuedEpoch:)``'s
            // doc comment for why eagerly issuing a token here,
            // unconditionally, before knowing whether this call will
            // join an already in-flight coalesced revalidation or create
            // fresh work, would clobber `keyLatestToken[key]` out from
            // under whatever fetch it might join.
            let epoch = await currentDurableClearEpoch()
            return try await revalidateExisting(
                existing,
                key: key,
                cacheKey: cacheKey,
                candidates: candidates,
                preIssuedEpoch: epoch
            )
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
    /// `preIssuedEpoch` is the durable clear epoch the caller already
    /// read (via ``currentDurableClearEpoch()``) at its own synchronous
    /// decision point, *before* calling this — never a full pre-issued
    /// ``CacheToken``. A full token cannot be safely threaded through
    /// here: both callers (the plain memory-hit branch, and the
    /// validated-disk-hit branch, which additionally holds its own
    /// separate token reserved purely for its own decode-authority
    /// re-check) call ``issueToken(for:)`` unconditionally for their own
    /// purposes, and ``issueToken(for:)`` always overwrites
    /// `keyLatestToken[key]` as a side effect — if that same
    /// already-issued token were then forwarded here and this call turns
    /// out to *join* an already in-flight coalesced revalidation for
    /// `key` (rather than create fresh work), the caller's own
    /// unconditionally-issued token would still have clobbered
    /// `keyLatestToken[key]` out from under the fetch actually in
    /// flight, permanently breaking every subsequent
    /// ``isAuthoritative(_:for:)`` check for it. Passing only the raw
    /// epoch value defers the actual ``issueToken(for:)`` call to
    /// ``resolveRevalidationFetchID(expectedFormat:existing:slot:preIssuedEpoch:)``,
    /// which only performs it on the "create fresh work" branch —
    /// exactly mirroring ``coalescedFetch(key:cacheKey:candidates:)``'s
    /// own join-vs-create structure — while still carrying an epoch
    /// value read no later than this exact synchronous call site, so a
    /// cross-instance/cross-process clear landing after that read is
    /// still caught by every downstream authority check, and one
    /// landing before it can never be silently laundered as if it
    /// postdated this revalidation's issuance.
    func revalidateExisting(
        _ existing: CachedAsset,
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate],
        preIssuedEpoch: Int?
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
            preIssuedEpoch: preIssuedEpoch
        )
    }

    /// The fetch identity and authoritative token a caller of
    /// ``resolveRevalidationFetchID(expectedFormat:existing:slot:preIssuedEpoch:)``
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
    /// (minted here, for this call, from `preIssuedEpoch`). Split out of
    /// ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:preIssuedEpoch:)``
    /// purely to keep that function's body within this package's
    /// `function_body_length` limit.
    ///
    /// `preIssuedEpoch` is a durable clear epoch value the caller already
    /// read (never a full pre-issued ``CacheToken``) — see
    /// ``revalidateExisting(_:key:cacheKey:candidates:preIssuedEpoch:)``'s
    /// doc comment for why: minting the actual authoritative token (via
    /// ``issueToken(for:)``, which mutates `keyLatestToken[key]`) must
    /// happen *here*, and only on this exact branch, rather than
    /// unconditionally at the caller's own earlier synchronous decision
    /// point — a caller that unconditionally issues its own token before
    /// knowing whether this call will join or create fresh work would
    /// clobber whatever token an already in-flight fetch (found on the
    /// join branch below) is relying on, permanently breaking every
    /// subsequent ``isAuthoritative(_:for:)`` check for it. When a fetch
    /// is already registered for `slot`, this caller simply joins it
    /// (`preIssuedEpoch` is discarded entirely: the in-flight fetch's own
    /// token, issued and stamped when *it* started, already governs this
    /// shared operation's authority for every one of its waiters
    /// uniformly).
    func resolveRevalidationFetchID(
        expectedFormat: AssetFormat,
        existing: CachedAsset,
        slot: RevalidationSlot,
        preIssuedEpoch: Int?
    ) -> ResolvedRevalidationFetch {
        if let current = inFlightRevalidation[slot] {
            return ResolvedRevalidationFetch(id: current.id, token: current.token)
        }
        var token = issueToken(for: slot.cacheKey)
        token.durableClearEpoch = preIssuedEpoch
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
        inFlightRevalidation[slot] = newFetch
        let fetchID = newFetch.id
        Task { [weak self] in
            let result = await newTask.result
            await self?.completeRevalidation(slot, fetchID: fetchID, result: result)
        }
        return ResolvedRevalidationFetch(id: fetchID, token: token)
    }
}
