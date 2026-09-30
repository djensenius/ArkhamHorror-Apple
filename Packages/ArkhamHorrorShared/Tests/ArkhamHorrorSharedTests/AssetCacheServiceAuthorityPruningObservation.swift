@testable import ArkhamHorrorShared
import Foundation
import Testing

struct RevalidationBacklogChurnObservation: Equatable, Sendable {
    let busyKeyCount: Int
    let metrics: AssetCacheService.AuthorityBusyCheckMetrics
}

private struct BusyRevalidation: Sendable {
    let cacheKey: AssetCacheKey
    let task: Task<CachedAsset, Error>
}

extension AssetCacheServiceTests {
    /// Registers a revalidation-busy backlog, pads total tracked authority keys to capacity,
    /// then observes deterministic busy-check counters while distinct disjoint keys churn.
    func observeChurnAgainstRevalidationBacklog(
        busyKeyCount: Int,
        touchCount: Int,
        keyPrefix: Int
    ) async throws -> RevalidationBacklogChurnObservation {
        var observation = RevalidationBacklogChurnObservation(
            busyKeyCount: busyKeyCount,
            metrics: AssetCacheService.AuthorityBusyCheckMetrics()
        )
        try await withService { service, _ in
            let busyRevalidations = try await registerRevalidationBusyKeys(
                service: service,
                busyKeyCount: busyKeyCount,
                keyPrefix: keyPrefix
            )
            try await padAuthorityTrackingToCapacity(
                service: service,
                busyKeyCount: busyKeyCount,
                keyPrefix: keyPrefix
            )

            await service.resetAuthorityBusyCheckMetrics()
            try await touchDistinctAuthorityKeys(
                service: service,
                touchCount: touchCount,
                keyPrefix: keyPrefix
            )
            let metrics = await service.authorityBusyCheckMetrics
            observation = RevalidationBacklogChurnObservation(
                busyKeyCount: busyKeyCount,
                metrics: metrics
            )

            await assertBusyRevalidationsStayedTracked(busyRevalidations, service: service)
            busyRevalidations.forEach { $0.task.cancel() }
        }
        return observation
    }

    private func registerRevalidationBusyKeys(
        service: AssetCacheService,
        busyKeyCount: Int,
        keyPrefix: Int
    ) async throws -> [BusyRevalidation] {
        var busyRevalidations: [BusyRevalidation] = []
        for index in 0 ..< busyKeyCount {
            let rawCode = String(format: "%d%05d", keyPrefix, index)
            let cacheKey = try distinctCacheKey(rawCode)
            let token = await stampedToken(for: service, key: cacheKey)
            let task = Task<CachedAsset, Error> {
                try await Task.sleep(nanoseconds: .max)
                throw CancellationError()
            }
            let slot = try AssetCacheService.RevalidationSlot(
                cacheKey: cacheKey,
                url: candidateURLs(for: cardArtKey(rawCode))[0],
                etag: "etag-\(rawCode)",
                lastModified: nil
            )
            let fetch = AssetCacheService.RevalidationFetch(task: task, token: token)
            await service.setInFlightRevalidation(fetch, for: slot)
            busyRevalidations.append(BusyRevalidation(cacheKey: cacheKey, task: task))
        }
        return busyRevalidations
    }

    private func padAuthorityTrackingToCapacity(
        service: AssetCacheService,
        busyKeyCount: Int,
        keyPrefix: Int
    ) async throws {
        let fillerKeyCount = AssetCacheService.maxTrackedAuthorityKeys - busyKeyCount
        for index in 0 ..< fillerKeyCount {
            let rawCode = String(format: "%d%05d", keyPrefix + 4, index)
            let cacheKey = try distinctCacheKey(rawCode)
            _ = await service.issueToken(for: cacheKey)
        }
    }

    private func touchDistinctAuthorityKeys(
        service: AssetCacheService,
        touchCount: Int,
        keyPrefix: Int
    ) async throws {
        for index in 0 ..< touchCount {
            let rawCode = String(format: "%d%05d", keyPrefix, index + 90000)
            let cacheKey = try distinctCacheKey(rawCode)
            _ = await service.issueToken(for: cacheKey)
            try await service.invalidate(cacheKey)
        }
    }

    private func assertBusyRevalidationsStayedTracked(
        _ busyRevalidations: [BusyRevalidation],
        service: AssetCacheService
    ) async {
        for busyRevalidation in busyRevalidations {
            let stillTracked = await service.trackedAuthorityKeys.contains(
                busyRevalidation.cacheKey
            )
            #expect(stillTracked, "a busy in-flight-revalidation key must never be pruned")
        }
    }
}
