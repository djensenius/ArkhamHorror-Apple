@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Sidecar schema-version gating at read time (reusing
/// `AssetDiskCacheTests`' fixture helpers by composition).
///
/// ``AssetCacheMetadata/currentSchemaVersion`` was bumped to 5 when the
/// per-entry publication field changed from an integer write generation
/// to a random ``AuthorityID``. The bump is what makes rejecting an
/// older sidecar an explicit, version-driven decision rather than an
/// incidental consequence of a renamed `Codable` key.
@Suite("AssetDiskCache sidecar schema version gating")
struct AssetDiskCacheSchemaVersionTests {
    private let fixtures = AssetDiskCacheTests()

    @Test(
        """
        A sidecar written in the previous, perfectly well-formed schema 4 -- back when the \
        publication field was an \
        integer write generation rather than a random authority identifier -- is quarantined at \
        read time on the \
        strength of its declared version alone, not decoded, and not mistaken for a pristine entry.
        """
    )
    func wellFormedPreviousSchemaSidecarQuarantined() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: fixtures.smallLimits())
            let cacheKey = try fixtures.key("01001")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: fixtures.metadata(for: cacheKey, payload: payload)
            )

            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            var json = try #require(
                try JSONSerialization
                    .jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
            )
            json["schemaVersion"] = 4
            json["authorityIDAtPublication"] = nil
            json["writeGenerationAtPublication"] = 1
            try JSONSerialization.data(withJSONObject: json).write(to: metadataURL)

            #expect(try await cache.get(cacheKey) == nil)
            #expect(try await cache.get(cacheKey) == nil, "and stays rejected on re-read")
        }
    }
}
