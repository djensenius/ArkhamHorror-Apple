import Foundation

/// Test-only instrumentation hook installers for ``AssetCacheService``,
/// split out of the main file purely to stay under this package's
/// file-length limit.
extension AssetCacheService {
    /// Test-only: installs ``testOnlyDiskPersistenceRecordedHook``.
    /// A plain actor-isolated method (rather than exposing the stored
    /// property for direct external assignment) so a test's call site
    /// reads as an ordinary, obviously-`await`-requiring actor call.
    func installTestOnlyDiskPersistenceRecordedHook(_ hook: @escaping () -> Void) {
        testOnlyDiskPersistenceRecordedHook = hook
    }

    /// Test-only: installs ``testOnlyPauseBeforeRevalidationRequest``.
    func installTestOnlyPauseBeforeRevalidationNetworkStep(_ hook: @escaping () async -> Void) {
        testOnlyPauseBeforeRevalidationRequest = hook
    }

    /// Test-only: installs ``testOnlyPauseAfterFetchPublishApplied``.
    func installTestOnlyPauseAfterFetchPublishApplied(_ hook: @escaping () async -> Void) {
        testOnlyPauseAfterFetchPublishApplied = hook
    }

    /// Test-only: installs ``testOnlyBeforeFetchResumesWaiters``.
    func installTestOnlyBeforeFetchResumesWaiters(_ hook: @escaping () -> Void) {
        testOnlyBeforeFetchResumesWaiters = hook
    }

    /// Test-only: installs ``testOnlyBeforeRevalidationResumesWaiters``.
    func installTestOnlyBeforeRevalidationResumesWaiters(_ hook: @escaping () -> Void) {
        testOnlyBeforeRevalidationResumesWaiters = hook
    }

    /// Test-only: installs ``testOnlyPauseBeforeMemoryFinalCAS``.
    func installTestOnlyPauseBeforeFinalMemoryAuthorityCAS(_ hook: @escaping () async -> Void) {
        testOnlyPauseBeforeMemoryFinalCAS = hook
    }

    /// Test-only: installs ``testOnlyPauseHoldingIssuanceLock``.
    func installTestOnlyPauseHoldingIssuanceLock(_ hook: @escaping () async -> Void) {
        testOnlyPauseHoldingIssuanceLock = hook
    }

    /// Test-only observability accessor: the number of callers currently
    /// queued (neither granted nor yet cancelled/resumed) behind `key`'s
    /// issuance decision lock — see
    /// `AssetCacheService+IssuanceDecisionLock.swift`'s type-level doc
    /// comment. Exists purely so a test can deterministically confirm "a
    /// second caller has genuinely joined this key's queue" before acting
    /// on it (e.g. cancelling it), rather than approximating that with a
    /// timing guess. Read-only and side-effect-free; harmless in a
    /// release build.
    func issuanceDecisionWaiterCount(for key: AssetCacheKey) -> Int {
        issuanceDecisionWaiters[key]?.count ?? 0
    }
}
