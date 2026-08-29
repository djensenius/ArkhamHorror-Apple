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
            accessSequence: AssetAccessSequence(0)
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

    @Test("accessSequence always serializes to the same fixed width regardless of its value")
    func accessSequenceSerializesToAFixedWidth() {
        // `AssetMemoryCache`'s per-entry accounted-byte-count is computed
        // once at construction and never re-measured on every subsequent
        // touch (see `CachedAsset.accountedByteCount`'s doc comment); that
        // optimization is only correct if `accessSequence`'s serialized
        // footprint truly never changes as the underlying integer grows,
        // from `0` all the way to `Int.max`.
        let zero = metadata(resolvedURLString: "https://example.com/a.avif")
        var large = zero
        large.accessSequence = AssetAccessSequence(Int.max)
        #expect(zero.metadataOverheadBytes == large.metadataOverheadBytes)
    }

    @Test("AssetAccessSequence round-trips through JSON for boundary values including > 2^53")
    func accessSequenceRoundTripsBoundaryValues() throws {
        for value in [0, 1, 1 << 53, (1 << 53) + 1, Int.max - 1, Int.max] {
            let sequence = AssetAccessSequence(value)
            let data = try JSONEncoder.assetCache().encode(["sequence": sequence])
            let decoded = try JSONDecoder.assetCache().decode(
                [String: AssetAccessSequence].self,
                from: data
            )
            #expect(decoded["sequence"] == sequence)
        }
    }
}
