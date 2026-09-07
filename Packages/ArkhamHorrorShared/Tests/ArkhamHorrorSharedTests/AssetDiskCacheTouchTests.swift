@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Metadata-only `touch(_:metadata:)` coverage for ``AssetDiskCache``, split
/// out of `AssetDiskCacheTests.swift` (which retains the shared
/// `withScratchDirectory`/`key`/`metadata`/`smallLimits` helpers) purely to
/// stay under SwiftLint's `type_body_length`, the same way
/// `AssetDiskCacheAtomicityTests` is split by concern into its own file.
extension AssetDiskCacheTests {
    @Test(
        "touch(_:metadata:) rewrites only the metadata sidecar, leaving the payload file untouched"
    )
    func touchRewritesOnlyMetadataNotPayload() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: payload
            )
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            let beforeAttributes = try FileManager.default
                .attributesOfItem(atPath: payloadURL.path)
            let beforeModificationDate = try #require(
                beforeAttributes[.modificationDate] as? Date
            )

            let refreshedMetadata = try #require(await cache.get(cacheKey)).metadata
            let sequenceBeforeTouch = refreshedMetadata.accessSequence
            try await cache.touch(cacheKey, metadata: refreshedMetadata)

            let afterAttributes = try FileManager.default.attributesOfItem(atPath: payloadURL.path)
            let afterModificationDate = try #require(afterAttributes[.modificationDate] as? Date)
            #expect(afterModificationDate == beforeModificationDate)
            #expect(try Data(contentsOf: payloadURL) == payload)

            // Read the persisted sidecar directly rather than through
            // `get(_:)`, since `get(_:)` itself always bumps
            // `accessSequence` again on every read — using it here would
            // advance the very value this test is verifying
            // `touch(_:metadata:)` persisted. `JSONDecoder.assetCache` is
            // not file-private (only `AssetDiskCache`'s own recovery code
            // and this test file are outside its declaring file), so
            // decode with that exact decoder rather than a separately
            // constructed one.
            let persistedMetadata = try JSONDecoder.assetCache().decode(
                AssetCacheMetadata.self,
                from: Data(contentsOf: metadataURL)
            )
            // `touch(_:metadata:)` always stamps its own freshly allocated
            // sequence value — never whatever value the caller happened
            // to pass in `refreshedMetadata` — so this can only assert
            // that it advanced strictly past what `get(_:)` had already
            // stamped moments earlier, not that any particular caller-set
            // value round-tripped unchanged.
            #expect(persistedMetadata.accessSequence.value > sequenceBeforeTouch.value)
        }
    }

    @Test("touch(_:metadata:) throws rather than creating an orphaned metadata-only entry")
    func touchWithNoExistingPayloadThrowsWithoutCreatingOrphan() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])

            await #expect(throws: AssetError.self) {
                try await cache.touch(
                    cacheKey,
                    metadata: self.metadata(for: cacheKey, payload: payload)
                )
            }

            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
        }
    }

    @Test(
        """
        touch(_:metadata:) rejects a metadata.cacheKeyHex that does not match the AssetCacheKey \
        being touched, rather than persisting a sidecar that later reads as belonging to a \
        different key's own entry
        """
    )
    func touchRejectsMismatchedCacheKeyHexWithoutPersistingSidecar() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let otherKey = try key("01002")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            let mismatchedMetadata = metadata(for: otherKey, payload: payload)
            await #expect(throws: AssetError.self) {
                try await cache.touch(cacheKey, metadata: mismatchedMetadata)
            }

            // The pre-existing, correctly-keyed sidecar must survive
            // completely untouched: the rejected call must never have
            // overwritten it with the mismatched metadata.
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            let persistedMetadata = try JSONDecoder.assetCache().decode(
                AssetCacheMetadata.self,
                from: Data(contentsOf: metadataURL)
            )
            #expect(persistedMetadata.cacheKeyHex == cacheKey.digestHex)
        }
    }
}
