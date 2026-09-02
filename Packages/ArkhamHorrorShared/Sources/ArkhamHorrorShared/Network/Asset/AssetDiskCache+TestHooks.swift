import Foundation

/// Test-only pause-injection installers for ``AssetDiskCache``. Split out
/// of `AssetDiskCache.swift` purely to keep that file within this
/// package's `file_length` convention; still part of the same actor's
/// own isolated state.
extension AssetDiskCache {
    /// Test-only: installs ``testOnlyPauseBeforeReturningHit``. A plain
    /// actor-isolated method (rather than exposing the stored property for
    /// direct external assignment) so a test's call site reads as an
    /// ordinary, obviously-`await`-requiring actor call.
    func installTestOnlyPauseBeforeReturningHit(_ pause: @escaping () async -> Void) {
        testOnlyPauseBeforeReturningHit = pause
    }

    /// Test-only: installs ``testOnlyPauseBeforeAcquiringWriteLock``. See
    /// ``installTestOnlyPauseBeforeReturningHit(_:)`` for the rationale
    /// behind exposing this as a method rather than a settable property.
    func installTestOnlyPauseBeforeAcquiringWriteLock(_ pause: @escaping () async -> Void) {
        testOnlyPauseBeforeAcquiringWriteLock = pause
    }

    /// Test-only: installs ``testOnlyPauseBeforeAcquiringRemovalLock``.
    /// See ``installTestOnlyPauseBeforeReturningHit(_:)`` for the
    /// rationale behind exposing this as a method rather than a settable
    /// property.
    func installTestOnlyPauseBeforeAcquiringRemovalLock(_ pause: @escaping () async -> Void) {
        testOnlyPauseBeforeAcquiringRemovalLock = pause
    }
}
