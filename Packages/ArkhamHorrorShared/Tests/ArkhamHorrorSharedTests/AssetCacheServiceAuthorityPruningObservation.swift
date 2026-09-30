@testable import ArkhamHorrorShared
import Foundation
import Testing

struct RevalidationBacklogChurnObservation: Equatable, Sendable {
    let busyKeyCount: Int
    let trackedBusyKeyCount: Int
    let directoryEntryCountBeforeChurn: Int
    let listNamesCallsDuringChurn: Int
}

struct BusyRevalidation: Sendable {
    let cacheKey: AssetCacheKey
    let task: Task<CachedAsset, Error>
}

extension AssetCacheService {
    func testOnlySetRevalidationRefCount(_ count: Int?, for key: AssetCacheKey) {
        revalidationKeyRefCount[key] = count
    }
}

extension AssetCacheServiceTests {
    /// Registers a revalidation-busy backlog, pads total tracked authority keys to capacity,
    /// then churns distinct disjoint keys. The capacity padding is deliberate: the original
    /// tiny-backlog timing case never actually pruned during churn, while the large backlog did.
    func observeChurnAgainstRevalidationBacklog(
        busyKeyCount: Int,
        touchCount: Int,
        keyPrefix: Int
    ) async throws -> RevalidationBacklogChurnObservation {
        var observation = RevalidationBacklogChurnObservation(
            busyKeyCount: busyKeyCount,
            trackedBusyKeyCount: 0,
            directoryEntryCountBeforeChurn: 0,
            listNamesCallsDuringChurn: 0
        )
        try await withService { service, _ in
            let busyRevalidations = try await registerRevalidationBusyKeys(
                service: service,
                busyKeyCount: busyKeyCount,
                keyPrefix: keyPrefix
            )
            try await fillAuthorityTrackingToCapacity(
                service: service,
                existingTrackedKeyCount: busyKeyCount,
                keyPrefix: keyPrefix + 4
            )

            let directoryAccess = await service.diskCache.directoryAccess
            let entryCountBeforeChurn = try directoryAccess.listNames().count
            let listNamesCallsBeforeChurn = directoryAccess.listNamesCallCount
            try await touchDistinctAuthorityKeys(
                service: service,
                touchCount: touchCount,
                keyPrefix: keyPrefix
            )
            let listNamesCallsDuringChurn = directoryAccess.listNamesCallCount
                - listNamesCallsBeforeChurn
            let trackedBusyKeyCount = await countTrackedBusyRevalidations(
                busyRevalidations,
                service: service
            )
            observation = RevalidationBacklogChurnObservation(
                busyKeyCount: busyKeyCount,
                trackedBusyKeyCount: trackedBusyKeyCount,
                directoryEntryCountBeforeChurn: entryCountBeforeChurn,
                listNamesCallsDuringChurn: listNamesCallsDuringChurn
            )

            await assertBusyRevalidationsStayedTracked(busyRevalidations, service: service)
            busyRevalidations.forEach { $0.task.cancel() }
        }
        return observation
    }

    func registerRevalidationBusyKey(
        service: AssetCacheService,
        rawCode: String
    ) async throws -> BusyRevalidation {
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
        return BusyRevalidation(cacheKey: cacheKey, task: task)
    }

    func fillAuthorityTrackingToCapacity(
        service: AssetCacheService,
        existingTrackedKeyCount: Int,
        keyPrefix: Int
    ) async throws {
        let fillerKeyCount = AssetCacheService.maxTrackedAuthorityKeys - existingTrackedKeyCount
        for index in 0 ..< fillerKeyCount {
            let rawCode = String(format: "%d%05d", keyPrefix, index)
            let cacheKey = try distinctCacheKey(rawCode)
            _ = await service.issueToken(for: cacheKey)
        }
    }

    private func registerRevalidationBusyKeys(
        service: AssetCacheService,
        busyKeyCount: Int,
        keyPrefix: Int
    ) async throws -> [BusyRevalidation] {
        var busyRevalidations: [BusyRevalidation] = []
        for index in 0 ..< busyKeyCount {
            let rawCode = String(format: "%d%05d", keyPrefix, index)
            let busy = try await registerRevalidationBusyKey(service: service, rawCode: rawCode)
            busyRevalidations.append(busy)
        }
        return busyRevalidations
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

    private func countTrackedBusyRevalidations(
        _ busyRevalidations: [BusyRevalidation],
        service: AssetCacheService
    ) async -> Int {
        var trackedCount = 0
        for busyRevalidation in busyRevalidations {
            let stillTracked = await service.trackedAuthorityKeys.contains(
                busyRevalidation.cacheKey
            )
            if stillTracked {
                trackedCount += 1
            }
        }
        return trackedCount
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
