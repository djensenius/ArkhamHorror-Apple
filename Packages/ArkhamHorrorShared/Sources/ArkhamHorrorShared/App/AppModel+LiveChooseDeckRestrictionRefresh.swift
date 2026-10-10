import Foundation

extension AppModel {
    func refreshLiveChooseDeckRestriction(for gameID: GameID) async {
        let context = liveChooseDeckRestrictionContext(for: gameID)
        let cacheKey = liveChooseDeckRestrictionCacheKey(for: context)

        guard shouldRefreshLiveChooseDeckRestriction(for: gameID, cacheKey: cacheKey) else {
            return
        }
        guard context.shouldCheckCatalog else {
            storeUnrestrictedLiveChooseDeckRestriction(
                for: gameID,
                cacheKey: cacheKey,
                scenarioID: context.scenarioID
            )
            return
        }

        let refreshKey = LiveChooseDeckRestrictionRefreshKey(gameID: gameID, cacheKey: cacheKey)
        let refresh = liveChooseDeckRestrictionRefresh(
            for: refreshKey,
            context: context
        )
        defer { clearLiveChooseDeckRestrictionRefresh(refresh, for: refreshKey) }

        liveChooseDeckRestrictionChecks[gameID] = .loading
        do {
            let check = try await refresh.task.value
            try Task.checkCancellation()
            applyLiveChooseDeckRestrictionRefresh(
                check,
                for: gameID,
                cacheKey: cacheKey
            )
        } catch is CancellationError {
            handleLiveChooseDeckRestrictionRefreshCancellation(
                refresh,
                refreshKey: refreshKey,
                gameID: gameID,
                cacheKey: cacheKey
            )
        } catch {
            handleLiveChooseDeckRestrictionRefreshFailure(
                for: gameID,
                cacheKey: cacheKey,
                context: context
            )
        }
    }

    private func shouldRefreshLiveChooseDeckRestriction(
        for gameID: GameID,
        cacheKey: LiveChooseDeckRestrictionCacheKey
    ) -> Bool {
        liveChooseDeckRestrictionCacheKeys[gameID] != cacheKey ||
            liveChooseDeckRestrictionChecks[gameID] == nil ||
            liveChooseDeckRestrictionChecks[gameID] == .loading
    }

    private func storeUnrestrictedLiveChooseDeckRestriction(
        for gameID: GameID,
        cacheKey: LiveChooseDeckRestrictionCacheKey,
        scenarioID: String?
    ) {
        liveChooseDeckRestrictionChecks[gameID] = .unrestricted(scenarioID: scenarioID)
        liveChooseDeckRestrictionCacheKeys[gameID] = cacheKey
    }

    private func liveChooseDeckRestrictionRefresh(
        for refreshKey: LiveChooseDeckRestrictionRefreshKey,
        context: LiveChooseDeckRestrictionContext
    ) -> LiveChooseDeckRestrictionRefresh {
        if let currentRefresh = liveChooseDeckRestrictionRefreshes[refreshKey] {
            return currentRefresh
        }
        let refresh = LiveChooseDeckRestrictionRefresh(
            id: UUID(),
            task: Task { try await self.loadLiveChooseDeckRestriction(for: context) }
        )
        liveChooseDeckRestrictionRefreshes[refreshKey] = refresh
        return refresh
    }

    private func clearLiveChooseDeckRestrictionRefresh(
        _ refresh: LiveChooseDeckRestrictionRefresh,
        for refreshKey: LiveChooseDeckRestrictionRefreshKey
    ) {
        guard liveChooseDeckRestrictionRefreshes[refreshKey]?.id == refresh.id else { return }
        liveChooseDeckRestrictionRefreshes[refreshKey] = nil
    }

    private func applyLiveChooseDeckRestrictionRefresh(
        _ check: LiveChooseDeckRestrictionCheck,
        for gameID: GameID,
        cacheKey: LiveChooseDeckRestrictionCacheKey
    ) {
        guard currentLiveChooseDeckRestrictionCacheKey(for: gameID) == cacheKey else {
            clearUnownedStaleLiveChooseDeckRestrictionLoading(
                for: gameID,
                staleCacheKey: cacheKey
            )
            return
        }
        liveChooseDeckRestrictionChecks[gameID] = check
        liveChooseDeckRestrictionCacheKeys[gameID] = cacheKey
    }

    private func handleLiveChooseDeckRestrictionRefreshCancellation(
        _ refresh: LiveChooseDeckRestrictionRefresh,
        refreshKey: LiveChooseDeckRestrictionRefreshKey,
        gameID: GameID,
        cacheKey: LiveChooseDeckRestrictionCacheKey
    ) {
        guard !Task.isCancelled else { return }
        guard liveChooseDeckRestrictionRefreshes[refreshKey]?.id == refresh.id else { return }
        guard currentLiveChooseDeckRestrictionCacheKey(for: gameID) == cacheKey else {
            clearUnownedStaleLiveChooseDeckRestrictionLoading(
                for: gameID,
                staleCacheKey: cacheKey
            )
            return
        }
        liveChooseDeckRestrictionChecks[gameID] = nil
        liveChooseDeckRestrictionCacheKeys[gameID] = nil
    }

    private func handleLiveChooseDeckRestrictionRefreshFailure(
        for gameID: GameID,
        cacheKey: LiveChooseDeckRestrictionCacheKey,
        context: LiveChooseDeckRestrictionContext
    ) {
        guard currentLiveChooseDeckRestrictionCacheKey(for: gameID) == cacheKey else {
            clearUnownedStaleLiveChooseDeckRestrictionLoading(
                for: gameID,
                staleCacheKey: cacheKey
            )
            return
        }
        liveChooseDeckRestrictionCacheKeys[gameID] = nil
        liveChooseDeckRestrictionChecks[gameID] = .unavailable(
            message: liveChooseDeckRestrictionUnavailableMessage(),
            scenarioID: context.scenarioID
        )
    }

    private func currentLiveChooseDeckRestrictionCacheKey(
        for gameID: GameID
    ) -> LiveChooseDeckRestrictionCacheKey {
        liveChooseDeckRestrictionCacheKey(for: liveChooseDeckRestrictionContext(for: gameID))
    }

    private func clearUnownedStaleLiveChooseDeckRestrictionLoading(
        for gameID: GameID,
        staleCacheKey: LiveChooseDeckRestrictionCacheKey
    ) {
        let currentCacheKey = currentLiveChooseDeckRestrictionCacheKey(for: gameID)
        let currentRefreshKey = LiveChooseDeckRestrictionRefreshKey(
            gameID: gameID,
            cacheKey: currentCacheKey
        )
        guard currentCacheKey != staleCacheKey else { return }
        if liveChooseDeckRestrictionCacheKeys[gameID] == staleCacheKey {
            liveChooseDeckRestrictionCacheKeys[gameID] = nil
        }
        guard liveChooseDeckRestrictionRefreshes[currentRefreshKey] == nil,
              liveChooseDeckRestrictionCacheKeys[gameID] == nil,
              liveChooseDeckRestrictionChecks[gameID] == .loading
        else { return }
        liveChooseDeckRestrictionChecks[gameID] = nil
    }
}
