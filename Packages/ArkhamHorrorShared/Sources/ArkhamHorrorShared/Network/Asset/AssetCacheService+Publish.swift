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
    /// this exact work cancelled. Callers that would otherwise return a
    /// value to their own caller as if this had landed must check this
    /// result (see `AssetCacheService+Fetch.swift`'s and
    /// `AssetCacheService+RevalidationCoalescing.swift`'s use of this).
    @discardableResult
    func publish(
        _ cacheKey: AssetCacheKey,
        asset: CachedAsset,
        token: CacheToken
    ) async -> MutationOutcome {
        guard isAuthoritative(token, for: cacheKey) else { return .stale }
        await memoryCache.set(cacheKey, asset: asset, token: token)
        guard isAuthoritative(token, for: cacheKey) else {
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
        await recordDiskPersistenceResult {
            try await diskCache.set(
                cacheKey,
                payload: asset.payload,
                metadata: asset.metadata,
                token: token
            )
        }
        guard isAuthoritative(token, for: cacheKey) else {
            // Same retraction, now for both layers: the disk write may
            // also have landed under `token` before this suspension
            // returned.
            await memoryCache.removeIfApplied(cacheKey, token: token)
            await diskCache.removeIfApplied(cacheKey, token: token)
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
    /// ``publish(_:asset:token:)`` does, and — like it — retracts any
    /// mutation this call itself already applied before reporting that
    /// outcome.
    @discardableResult
    func touch(
        _ cacheKey: AssetCacheKey,
        asset: CachedAsset,
        token: CacheToken
    ) async -> MutationOutcome {
        guard isAuthoritative(token, for: cacheKey) else { return .stale }
        await memoryCache.set(cacheKey, asset: asset, token: token)
        guard isAuthoritative(token, for: cacheKey) else {
            await memoryCache.removeIfApplied(cacheKey, token: token)
            return .stale
        }
        await recordDiskPersistenceResult {
            try await diskCache.touch(cacheKey, metadata: asset.metadata, token: token)
        }
        guard isAuthoritative(token, for: cacheKey) else {
            await memoryCache.removeIfApplied(cacheKey, token: token)
            await diskCache.removeIfApplied(cacheKey, token: token)
            return .stale
        }
        return .applied
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
    /// failure, or cancellation), so a test can deterministically wait
    /// for it rather than racing an unrelated coalesced waiter's own
    /// continuation resuming.
    private func recordDiskPersistenceResult(_ operation: () async throws -> Void) async {
        defer { testOnlyDiskPersistenceRecordedHook?() }
        do {
            try await operation()
            lastDiskPersistenceFailure = nil
        } catch is CancellationError {
        } catch let error as AssetError {
            lastDiskPersistenceFailure = error
        } catch {
            lastDiskPersistenceFailure = .cachePersistenceFailed(String(describing: error))
        }
    }
}
