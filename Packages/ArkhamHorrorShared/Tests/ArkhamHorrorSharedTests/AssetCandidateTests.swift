@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Regression coverage for ``AssetCandidate/url(base:)`` against a
/// non-empty ``AssetSourceNamespace/basePath``, guarding against
/// re-introducing a single `appendingPathComponent(base.basePath)` call
/// (the base path always includes its own leading `/`, so passed whole it
/// can be treated as one path component rather than one per segment).
@Suite("AssetCandidate URL construction")
struct AssetCandidateTests {
    private func candidate() throws -> AssetCandidate {
        let identifier = try AssetIdentifier.cardCode("01001")
        let key = AssetKey(source: .hosted, category: .card(.art, identifier))
        return AssetLocator.candidates(for: key, digest: FakeDigestLookup())[0]
    }

    @Test("A single-segment base path resolves each component under it, not percent-encoded")
    func singleSegmentBasePath() throws {
        let assetBase = try #require(URL(string: "https://example.com/cdn"))
        let base = try AssetSourceNamespace(assetBase: assetBase)
        let url = try candidate().url(base: base)
        #expect(url.absoluteString == "https://example.com:443/cdn/img/arkham/cards/01001.avif")
        #expect(!url.absoluteString.contains("%2F"))
    }

    @Test("A multi-segment base path resolves every segment, not as one component")
    func multiSegmentBasePath() throws {
        let assetBase = try #require(URL(string: "https://example.com/cdn/assets"))
        let base = try AssetSourceNamespace(assetBase: assetBase)
        let url = try candidate().url(base: base)
        #expect(
            url.absoluteString
                == "https://example.com:443/cdn/assets/img/arkham/cards/01001.avif"
        )
        #expect(!url.absoluteString.contains("%2F"))
    }

    @Test("An empty base path resolves directly under the origin")
    func emptyBasePath() throws {
        let url = try candidate().url(base: .hosted)
        let expected = "https://assets.arkhamhorror.app:443/img/arkham/cards/01001.avif"
        #expect(url.absoluteString == expected)
    }
}
