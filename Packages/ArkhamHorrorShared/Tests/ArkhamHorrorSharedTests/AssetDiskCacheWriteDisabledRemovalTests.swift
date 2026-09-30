@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Removal-specific coverage for `AssetDiskCache`'s disk-writes-disabled
/// state, split out of `AssetDiskCacheWriteDisabledTests.swift` to keep
/// that suite under the file-length limit.
extension AssetDiskCacheTests {
    @Test(
        """
        Tokenless remove remains allowed after a budget-proof failure has disabled ordinary \
        writes, because it overwrites/removes existing per-key state rather than admitting new \
        cache bytes or a new authority-record file.
        """
    )
    func tokenlessRemoveSucceedsWhileWritesAreDisabled() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: writeDisabledTestLimits())
            let cacheKey = try key("01001")
            let payload = Data(count: 100)
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            await cache.directoryAccess.installFaultInjection(listNamesFailuresRemaining: 999)
            await #expect(throws: AssetError.self) {
                let blockedKey = try key("01002")
                let blockedPayload = Data(count: 100)
                try await cache.set(
                    blockedKey,
                    payload: blockedPayload,
                    metadata: metadata(for: blockedKey, payload: blockedPayload)
                )
            }

            #expect(try await cache.remove(cacheKey) == .applied)
            let record = try await cache.currentKeyRecord(for: cacheKey)
            #expect(record.disposition.kind == .tombstone)
            #expect(record.openIssuanceOwnerID == nil)
            let fetched = try await cache.get(cacheKey)
            #expect(fetched == nil)
        }
    }
}
