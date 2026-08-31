import Foundation

/// `publish(_:asset:token:)`/`touch(_:asset:token:)` and their shared
/// disk-persistence-failure bookkeeping for `AssetCacheService`, split
/// out of `AssetCacheService.swift` purely to keep that file within this
/// package's `file_length` convention.
extension AssetCacheService {
    /// Publishes a resolved asset into both cache layers, gated by
    /// `token` at every hop: immediately before the memory-cache write,
    /// again immediately before the disk-cache write (a disk write is a
    /// second, independent suspension after the first), and — beyond this
    /// actor's own re-checks — ``AssetMemoryCache/set(_:asset:token:)``
    /// and ``AssetDiskCache/set(_:payload:metadata:token:)`` each
    /// independently re-verify the same token themselves before mutating
    /// their own state, so a write that loses the race strictly *within*
    /// one of those actor calls (not merely between this actor's own
    /// checks) still cannot land. The disk write is deliberately
    /// best-effort (an in-memory-only asset is still usable for the
    /// remainder of the process), but that decision is centralized here
    /// in an explicit `do`/`catch` — rather than a bare `try?` — so a
    /// persistence failure is captured in ``lastDiskPersistenceFailure``
    /// for auditing/instrumentation instead of vanishing silently. A
    /// successful disk write always clears `cacheKey`'s tombstone (see
    /// ``tombstonedKeys``): a fresh, verified generation on disk
    /// supersedes whatever an earlier failed deletion was protecting
    /// against.
    ///
    /// Returns ``MutationOutcome/stale`` (without having mutated
    /// anything further) the moment any of its own re-checks finds a
    /// more-recently-issued token already authoritative — including one
    /// retired by ``retireIfCurrent(_:for:)`` when the last waiter for
    /// this exact work cancelled — **or** the moment
    /// ``AssetDiskCache/set(_:payload:metadata:token:)``'s own disk-durable,
    /// cross-instance/cross-process CAS reports the write itself was
    /// rejected as stale. That second case is what actually closes this
    /// package's most persistently-flagged review finding: this actor's
    /// own ``isAuthoritative(_:for:)`` re-checks are purely in-process —
    /// they cannot see a completely independent sibling
    /// `AssetCacheService`/`AssetDiskCache` instance (or process) sharing
    /// this same on-disk directory that has already durably published a
    /// genuinely newer write for this exact key. Without folding the
    /// disk layer's own CAS outcome back into this method's result, this
    /// actor would report `.applied` — and keep serving its own,
    /// already-superseded bytes from memory indefinitely — purely
    /// because *its own* bookkeeping never learned a sibling had already
    /// won. Callers that would otherwise return a value to their own
    /// caller as if this had landed must check this result (see
    /// `AssetCacheService+Fetch.swift`'s and
    /// `AssetCacheService+RevalidationCoalescing.swift`'s use of this).
    @discardableResult
    func publish(
        _ cacheKey: AssetCacheKey,
        asset: CachedAsset,
        token: CacheToken
    ) async -> MutationOutcome {
        guard await isAuthoritative(token, for: cacheKey) else { return .stale }
        await memoryCache.set(cacheKey, asset: asset, token: token)
        guard await isAuthoritative(token, for: cacheKey) else {
            // The memory write above landed (this actor's own token CAS
            // passed inside `memoryCache.set`), but a more-recently-issued
            // operation (or `evictAll()`) has already superseded `token`
            // by the time this suspension returned. Retract exactly the
            // mutation this call performed under `token` — a caller
            // receiving `.stale` back from this method must never leave a
            // servable, now-orphaned entry resident in memory (this is
            // the exact retirement-fence-propagation gap a prior review
            // found: detecting staleness here is not the same as undoing
            // the mutation that already landed).
            await memoryCache.removeIfApplied(cacheKey, token: token)
            return .stale
        }
        // Disk half of the write. `recordDiskPersistenceResult` returns a
        // ``DiskMutationSignal`` distinguishing "the disk-durable,
        // cross-instance/cross-process CAS itself rejected this write as
        // stale" (``DiskMutationSignal/stale``) from an ordinary,
        // best-effort I/O failure (``DiskMutationSignal/otherFailure``,
        // survived exactly as before) — see this method's own doc
        // comment for why the former must be treated identically to this
        // actor's own in-process staleness re-check below, not silently
        // folded into best-effort handling.
        let diskSignal = await recordDiskPersistenceResult {
            try await diskCache.set(
                cacheKey,
                payload: asset.payload,
                metadata: asset.metadata,
                token: token
            )
        }
        guard diskSignal != .stale else {
            // The disk write itself was durably rejected: some other,
            // more-recently-issued sibling instance/process sharing this
            // same directory already published a newer write for this
            // exact key. This actor's own memory write above must not be
            // allowed to keep serving those now-superseded bytes.
            await memoryCache.removeIfApplied(cacheKey, token: token)
            return .stale
        }
        await testOnlyPauseBeforePublishFinalCAS?()
        guard await isAuthoritative(token, for: cacheKey) else {
            // A more-recently-issued operation (or `evictAll()`) has
            // already superseded `token` by the time this last
            // suspension returned, even though the disk write itself
            // just landed under it. Deliberately does **not** attempt
            // its own retraction here — see this method's own doc
            // comment for why: every caller of `publish(_:asset:token:)`
            // is exclusively mediated by the coalesced-fetch/-
            // revalidation waiter-acknowledgement ledger
            // (`AssetCacheService+WaiterAcknowledgement.swift`), which
            // *guarantees* its own group-level retraction eventually
            // runs whenever this method's shared operation's `Result` is
            // not a success for every one of its waiters (returning
            // anything other than `.applied` here causes exactly that —
            // see `AssetCacheService+Fetch.swift`/
            // `+RevalidationCompletion.swift`). A prior revision
            // additionally attempted its own, separate retraction right
            // here via `try?`, swallowing any failure of *that* specific
            // attempt — the exact defect a review round flagged: with
            // two or more waiters coalesced onto this same operation,
            // only the group's own last-finalizing waiter ever actually
            // awaited a retraction's outcome, so an earlier-finalizing
            // waiter could observe "stale" while this call's own,
            // separately-swallowed retraction attempt silently failed
            // and durable `content(token)` remained fully readable.
            // Relying solely on the one, shared, now-properly-broadcast
            // group-level retraction (every non-delivered waiter
            // suspends until it resolves — see this file's own
            // finalizeFetchWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:))
            // removes this redundant, racy attempt entirely rather than
            // trying to synchronize two independent retraction attempts
            // against each other.
            return .stale
        }
        if lastDiskPersistenceFailure == nil {
            tombstonedKeys.remove(cacheKey)
        }
        return .applied
    }

    /// Refreshes an already-cached asset's metadata only (for example
    /// bumping ``AssetCacheMetadata/accessSequence`` after a 304
    /// revalidation), without re-writing the unchanged payload bytes to
    /// disk. Gated by `token` at each hop exactly like ``publish(_:asset:token:)``.
    /// Falls back to the same best-effort, audited failure handling.
    /// Returns ``MutationOutcome/stale`` under the same conditions
    /// ``publish(_:asset:token:)`` does (including a disk-durable CAS
    /// rejection, not only this actor's own in-process re-checks), and —
    /// like it — retracts any mutation this call itself already applied
    /// before reporting that outcome.
    @discardableResult
    func touch(
        _ cacheKey: AssetCacheKey,
        asset: CachedAsset,
        token: CacheToken
    ) async -> MutationOutcome {
        guard await isAuthoritative(token, for: cacheKey) else { return .stale }
        await memoryCache.set(cacheKey, asset: asset, token: token)
        guard await isAuthoritative(token, for: cacheKey) else {
            await memoryCache.removeIfApplied(cacheKey, token: token)
            return .stale
        }
        let diskSignal = await recordDiskPersistenceResult {
            try await diskCache.touch(cacheKey, metadata: asset.metadata, token: token)
        }
        guard diskSignal != .entryGone, diskSignal != .stale else {
            // Both a definitive ``AssetError/entryNoLongerCachedToTouch``
            // (`.entryGone`) and a disk-durable CAS rejection (`.stale`)
            // are this cache's own proof that a more-recently-concluded
            // operation for `cacheKey` (a sibling instance/process
            // sharing this same disk directory included) already removed
            // or superseded the shared disk entry this touch was
            // refreshing, strictly *between* this actor's own token
            // authority checks above and the disk write actually reaching
            // that payload's on-disk name. Left alone, the memory write
            // already applied moments ago under this same (still locally
            // "authoritative") token would keep serving those now-
            // disowned bytes to every future in-process hit indefinitely,
            // entirely independent of what the shared disk cache itself
            // has since done — precisely the cross-instance authority gap
            // a purely in-process token check alone cannot close.
            // Deliberately does **not** attempt its own retraction here
            // — see ``publish(_:asset:token:)``'s identical guard for
            // why: the coalesced-fetch/-revalidation waiter-
            // acknowledgement ledger's own group-level retraction, which
            // every non-delivered waiter now suspends on until it
            // resolves, already guarantees this key's mutation is
            // retracted exactly once on behalf of the whole group; a
            // second, separately-swallowed attempt right here is exactly
            // the redundant, racy path a review round flagged.
            return .stale
        }
        await testOnlyPauseBeforePublishFinalCAS?()
        guard await isAuthoritative(token, for: cacheKey) else {
            return .stale
        }
        return .applied
    }

    /// The disk layer's own outcome for a single publish/touch attempt —
    /// what actually makes ``publish(_:asset:token:)``/``touch(_:asset:token:)``
    /// able to tell "this exact write's disk-durable, cross-instance/
    /// cross-process CAS was rejected as stale" apart from "the write was
    /// attempted and genuinely failed for an unrelated (I/O) reason",
    /// which a bare thrown-error/success distinction alone cannot: a CAS
    /// rejection is not a thrown error at all (``AssetDiskCache/set(_:payload:metadata:token:)``/
    /// ``AssetDiskCache/touch(_:metadata:token:)`` both return
    /// ``AssetCacheService/MutationOutcome/stale`` rather than throwing),
    /// and must be handled identically to this actor's own in-process
    /// staleness re-checks — not folded into the same best-effort/ignored
    /// handling as an ordinary transient I/O failure.
    private enum DiskMutationSignal: Equatable {
        case applied
        case stale
        case entryGone
        case otherFailure
    }

    /// Records the outcome of a best-effort disk-persistence `operation`
    /// into ``AssetCacheService/lastDiskPersistenceFailure``, deliberately
    /// distinguishing genuine failures from cooperative cancellation: a
    /// caller's task being cancelled while `operation` was itself
    /// suspended (for example on ``AssetDiskCache``'s cross-process lock,
    /// as the last remaining waiter for this exact fetch/revalidation) is
    /// not a disk-persistence *failure* -- the write was aborted, not
    /// attempted-and-failed -- so recording it as one would incorrectly
    /// leave ``AssetCacheService/lastDiskPersistenceFailure`` non-nil
    /// purely because of a cancellation race, in turn wrongly blocking
    /// the tombstone-clearing logic gated on it in ``publish(_:asset:token:)``.
    /// Leaves ``AssetCacheService/lastDiskPersistenceFailure`` exactly as
    /// it already was for a cancelled attempt, rather than clearing it
    /// either -- a cancelled attempt proves nothing one way or the other
    /// about whether disk persistence is currently healthy. Calls
    /// ``AssetCacheService/testOnlyDiskPersistenceRecordedHook``
    /// once this bookkeeping is complete, in every case (success, genuine
    /// failure, cancellation, or a CAS rejection), so a test can
    /// deterministically wait for it rather than racing an unrelated
    /// coalesced waiter's own continuation resuming.
    ///
    /// Returns ``DiskMutationSignal/entryGone`` only when `operation`
    /// threw ``AssetError/entryNoLongerCachedToTouch`` specifically — see
    /// that case's own doc comment for why ``touch(_:asset:token:)``
    /// alone (the only caller that can ever observe it;
    /// ``publish(_:asset:token:)``'s disk write never throws it) must
    /// treat that one outcome as a definitive cross-instance staleness
    /// signal rather than folding it into the same best-effort handling
    /// as every other disk failure. Returns ``DiskMutationSignal/stale``
    /// when `operation` completed without throwing but reported
    /// ``AssetCacheService/MutationOutcome/stale`` itself (the disk-layer
    /// CAS rejected this exact write) — both callers must treat this
    /// identically to `.entryGone`.
    private func recordDiskPersistenceResult(
        _ operation: () async throws -> MutationOutcome
    ) async -> DiskMutationSignal {
        defer { testOnlyDiskPersistenceRecordedHook?() }
        do {
            let outcome = try await operation()
            lastDiskPersistenceFailure = nil
            return outcome == .applied ? .applied : .stale
        } catch is CancellationError {
            return .otherFailure
        } catch AssetError.entryNoLongerCachedToTouch {
            lastDiskPersistenceFailure = .entryNoLongerCachedToTouch
            return .entryGone
        } catch let error as AssetError {
            lastDiskPersistenceFailure = error
            return .otherFailure
        } catch {
            lastDiskPersistenceFailure = .cachePersistenceFailed(String(describing: error))
            return .otherFailure
        }
    }
}
