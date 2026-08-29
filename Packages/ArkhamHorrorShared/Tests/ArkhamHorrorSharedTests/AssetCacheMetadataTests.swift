@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Regression coverage for ``AssetCacheMetadata/metadataOverheadBytes``:
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

    @Test("A metadata value with a very long resolved URL has proportionally more overhead")
    func longResolvedURLIncreasesMetadataOverheadBytes() {
        let short = metadata(resolvedURLString: "https://example.com/a.avif")
        let long = metadata(
            resolvedURLString: "https://example.com/" + String(repeating: "a", count: 4096) +
                ".avif"
        )
        // A fixed-size estimate would bill these identically (both are
        // still well under any single fixed constant); a real measurement
        // must reflect the actual difference in serialized size.
        #expect(long.metadataOverheadBytes - short.metadataOverheadBytes >= 4090)
    }

    @Test("The metadata overhead exceeding the old fixed 512-byte estimate is still fully billed")
    func overheadExceedingOldFixedEstimateIsFullyBilled() {
        let veryLong = metadata(
            resolvedURLString: "https://example.com/" + String(repeating: "a", count: 2000)
        )
        #expect(veryLong.metadataOverheadBytes > AssetCacheMetadata.estimatedMetadataOverheadBytes)
    }

    @Test("metadataOverheadBytes measures only the metadata JSON, never the declared payload size")
    func metadataOverheadBytesExcludesEncodedByteCount() {
        let small = metadata(resolvedURLString: "https://example.com/a.avif")
        // The metadata JSON overhead is orders of magnitude smaller than
        // the (unrelated) declared payload size configured in the helper
        // above: if this property still folded in `encodedByteCount` (as
        // the old, now-removed `accountedByteCount` did), it would be at
        // least 1000.
        #expect(small.metadataOverheadBytes < small.encodedByteCount)
    }
}
