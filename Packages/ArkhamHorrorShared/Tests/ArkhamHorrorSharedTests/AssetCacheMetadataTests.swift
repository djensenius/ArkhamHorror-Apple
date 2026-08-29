@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Regression coverage for ``AssetCacheMetadata/accountedByteCount``:
/// in-memory quota accounting must measure this value's actual serialized
/// size rather than a fixed estimate, since ``AssetCacheMetadata/resolvedURLString``
/// has no fixed upper bound and a long one could otherwise be silently
/// under-billed against the configured memory budget.
@Suite("AssetCacheMetadata accounting")
struct AssetCacheMetadataTests {
    private func metadata(resolvedURLString: String) -> AssetCacheMetadata {
        AssetCacheMetadata(
            cacheKeyHex: String(repeating: "a", count: 64),
            contentType: "image/png",
            encodedByteCount: 1000,
            width: 4,
            height: 4,
            payloadSHA256Hex: String(repeating: "b", count: 64),
            etag: nil,
            lastModified: nil,
            resolvedURLString: resolvedURLString,
            insertedAt: Date(timeIntervalSince1970: 0),
            lastAccessedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("A metadata value with a very long resolved URL is billed proportionally more")
    func longResolvedURLIncreasesAccountedByteCount() {
        let short = metadata(resolvedURLString: "https://example.com/a.avif")
        let long = metadata(
            resolvedURLString: "https://example.com/" + String(repeating: "a", count: 4096) +
                ".avif"
        )
        // A fixed-size estimate would bill these identically (both are
        // still well under any single fixed constant); a real measurement
        // must reflect the actual difference in serialized size.
        #expect(long.accountedByteCount - short.accountedByteCount >= 4090)
    }

    @Test("The metadata overhead exceeding the old fixed 512-byte estimate is still fully billed")
    func overheadExceedingOldFixedEstimateIsFullyBilled() {
        let veryLong = metadata(
            resolvedURLString: "https://example.com/" + String(repeating: "a", count: 2000)
        )
        let overhead = veryLong.accountedByteCount - veryLong.encodedByteCount
        #expect(overhead > AssetCacheMetadata.estimatedMetadataOverheadBytes)
    }

    @Test("accountedByteCount always includes the full encoded payload byte count")
    func accountedByteCountIncludesPayloadBytes() {
        let value = metadata(resolvedURLString: "https://example.com/a.avif")
        #expect(value.accountedByteCount >= value.encodedByteCount)
    }
}
