import Foundation

/// Terminal durable-issuance settlement for `AssetCacheService`.
extension AssetCacheService {
    /// Settles a reservation even when the surrounding producer task was
    /// cancelled. `SecureCacheDirectory` deliberately observes caller
    /// cancellation while waiting for its lock, so this uses an awaited,
    /// detached task rather than an unawaited cleanup task.
    nonisolated static func settleIssuedOperation(
        _ diskCache: AssetDiskCache,
        cacheKey: AssetCacheKey,
        token: CacheToken
    ) async throws {
        guard token.durableClearEpoch != nil, token.diskAuthorityID != nil else { return }
        _ = try await Task.detached {
            try await diskCache.settleIssuance(cacheKey, token: token)
        }.value
    }

    func settleIssuedOperation(_ cacheKey: AssetCacheKey, token: CacheToken) async throws {
        try await Self.settleIssuedOperation(diskCache, cacheKey: cacheKey, token: token)
    }

    /// Preserves the operation's original terminal result while making a
    /// failed durable cleanup visible to the service's existing
    /// persistence-failure diagnostics. The disk layer releases the
    /// operation lock before this I/O starts, so even a failed record
    /// update cannot leave a publishable authority pinned indefinitely.
    func settleIssuedOperationAfterTerminalOutcome(
        _ cacheKey: AssetCacheKey,
        token: CacheToken
    ) async {
        do {
            try await settleIssuedOperation(cacheKey, token: token)
        } catch let error as AssetError {
            lastDiskPersistenceFailure = error
        } catch {
            lastDiskPersistenceFailure = .cachePersistenceFailed(String(describing: error))
        }
    }

    func issuedFetchTask(
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate],
        token: CacheToken
    ) -> Task<CachedAsset, Error> {
        let diskCache = diskCache
        return Task { [weak self, diskCache] in
            guard let self else {
                _ = try? await Self.settleIssuedOperation(
                    diskCache,
                    cacheKey: cacheKey,
                    token: token
                )
                throw CancellationError()
            }
            do {
                let result = try await fetchAndValidate(
                    key: key,
                    cacheKey: cacheKey,
                    candidates: candidates,
                    token: token
                )
                await settleIssuedOperationAfterTerminalOutcome(cacheKey, token: token)
                return result
            } catch {
                await settleIssuedOperationAfterTerminalOutcome(cacheKey, token: token)
                throw error
            }
        }
    }

    func issuedRevalidationTask(
        request: RevalidationRequest,
        slot: RevalidationSlot
    ) -> Task<CachedAsset, Error> {
        let diskCache = diskCache
        return Task { [weak self, diskCache] in
            guard let self else {
                _ = try? await Self.settleIssuedOperation(
                    diskCache,
                    cacheKey: slot.cacheKey,
                    token: request.token
                )
                throw CancellationError()
            }
            do {
                let result = try await performRevalidation(request)
                await settleIssuedOperationAfterTerminalOutcome(
                    slot.cacheKey,
                    token: request.token
                )
                return result
            } catch {
                await settleIssuedOperationAfterTerminalOutcome(
                    slot.cacheKey,
                    token: request.token
                )
                throw error
            }
        }
    }
}
