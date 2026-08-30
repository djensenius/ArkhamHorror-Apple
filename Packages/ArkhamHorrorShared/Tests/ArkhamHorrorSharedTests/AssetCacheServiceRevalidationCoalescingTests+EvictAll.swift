@testable import ArkhamHorrorShared
import Foundation
import Testing

/// `evictAll()` interacting with a suspended, coalesced revalidation
/// waiter, split out of
/// `AssetCacheServiceRevalidationCoalescingTests.swift` purely to keep
/// that file within this package's `file_length` limit -- both files
/// together cover revalidation coalescing/cancellation for
/// ``AssetCacheService/revalidate(for:)``.
extension AssetCacheServiceTests {
    @Test(
        """
        evictAll() resumes every waiter still suspended in a coalescedRevalidation it is about \
        to tear down (with CancellationError) rather than silently dropping the in-flight entry \
        and leaving that waiter's continuation unresumed forever
        """
    )
    func evictAllResumesSuspendedRevalidationWaitersRatherThanHangingThem() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(successResult(etag: "\"v1\"")), for: urls[0])
            _ = try await service.asset(for: key)

            await transport.hold(urls[0])
            await transport.enqueue(.success(successResult(etag: "\"v2\"")), for: urls[0])

            let waiterTask = Task { try await service.revalidate(for: key) }
            await transport.waitForCallCount(2, for: urls[0])
            try await Task.sleep(nanoseconds: 20_000_000)

            try await service.evictAll()
            await transport.release(urls[0])

            let result = await withTaskGroup(
                of: Result<CachedAsset, Error>?.self,
                returning: Result<CachedAsset, Error>?.self
            ) { group in
                group.addTask { () -> Result<CachedAsset, Error>? in
                    await waiterTask.result
                }
                group.addTask { () -> Result<CachedAsset, Error>? in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return nil
                }
                let first: Result<CachedAsset, Error>?? = await group.next()
                group.cancelAll()
                return first ?? nil
            }
            guard let result else {
                Issue.record(
                    """
                    evictAll() must resume every suspended revalidation waiter; this one \
                    hung instead
                    """
                )
                return
            }
            #expect(throws: (any Error).self) { try result.get() }
            if case let .failure(error) = result {
                #expect(error is CancellationError, "Expected CancellationError, got \(error)")
            }
        }
    }
}
