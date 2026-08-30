@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic coalesced-waiter synchronization helpers, shared by
/// `AssetCacheServiceCoalescingTests.swift` and
/// `AssetCacheServiceRevalidationCoalescingTests.swift`. Split out of
/// `AssetCacheServiceTests.swift` purely to stay under SwiftLint's
/// `type_body_length`, the same way `AssetCacheServiceRevalidationTests`
/// is split by concern into its own file.
extension AssetCacheServiceTests {
    /// Polls ``AssetCacheService/inFlightWaiterCount(for:)`` until it
    /// reports exactly `count`, rather than assuming a fixed
    /// `Task.sleep` duration is always "long enough" for a coalesced
    /// waiter to join (or a cancelled waiter's cleanup to finish) --
    /// which ordinary scheduler jitter under load can make untrue, as
    /// observed in practice on constrained CI runners. Follows
    /// ``FakeAssetTransport/waitForCallCount(_:for:timeoutNanoseconds:)``'s
    /// identical bounded-poll-with-deadline shape.
    func waitForInFlightWaiterCount(
        _ count: Int,
        for key: AssetKey,
        on service: AssetCacheService,
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while try await service.inFlightWaiterCount(for: key) != count {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                preconditionFailure(
                    "waitForInFlightWaiterCount(\(count), for: \(key)) timed out"
                )
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Mirrors ``waitForInFlightWaiterCount(_:for:on:timeoutNanoseconds:)``
    /// for coalesced revalidations, re-deriving the same ``AssetCacheKey``
    /// ``revalidate(for:)`` itself computes.
    func waitForInFlightRevalidationWaiterCount(
        _ count: Int,
        for key: AssetKey,
        on service: AssetCacheService,
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) async throws {
        let candidates = try await service.resolvedCandidates(for: key)
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while await service.inFlightRevalidationWaiterCount(forCacheKey: cacheKey) != count {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                preconditionFailure(
                    "waitForInFlightRevalidationWaiterCount(\(count), for: \(key)) timed out"
                )
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
