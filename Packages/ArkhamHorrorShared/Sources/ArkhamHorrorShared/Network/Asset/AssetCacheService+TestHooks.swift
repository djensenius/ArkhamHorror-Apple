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
}
