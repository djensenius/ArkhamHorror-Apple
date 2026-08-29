@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("AssetCacheKey")
struct AssetCacheKeyTests {
    private func candidates(
        for key: AssetKey,
        digest: any LocalizedDigestLookup = FakeDigestLookup()
    ) -> [AssetCandidate] {
        AssetLocator.candidates(for: key, digest: digest)
    }

    @Test("The same key and candidates always produce the same digest")
    func deterministicForIdenticalInput() throws {
        let identifier = try AssetIdentifier.cardCode("01001")
        let key = AssetKey(category: .card(.art, identifier))
        let candidateList = candidates(for: key)
        let first = AssetCacheKey(for: key, candidates: candidateList)
        let second = AssetCacheKey(for: key, candidates: candidateList)
        #expect(first == second)
        #expect(first.digestHex == second.digestHex)
    }

    @Test("Distinct source namespaces never produce the same key, even for identical candidates")
    func distinctSourceProducesDistinctKey() throws {
        let identifier = try AssetIdentifier.cardCode("01001")
        let hostedKey = AssetKey(source: .hosted, category: .card(.art, identifier))
        let selfHosted = try AssetSourceNamespace(rawAssetBase: "http://localhost:9000")
        let selfHostedKey = AssetKey(source: selfHosted, category: .card(.art, identifier))
        let candidateList = candidates(for: hostedKey)

        let hostedCacheKey = AssetCacheKey(for: hostedKey, candidates: candidateList)
        let selfHostedCacheKey = AssetCacheKey(for: selfHostedKey, candidates: candidateList)
        #expect(hostedCacheKey != selfHostedCacheKey)
    }

    @Test(
        "Distinct candidate sequences never produce the same key, even for an identical abstract"
    )
    func distinctCandidatesProduceDistinctKey() throws {
        let identifier = try AssetIdentifier.cardCode("13093")
        let key = AssetKey(category: .card(.art, identifier), locale: .italian)
        let withoutLocalized = candidates(for: key, digest: FakeDigestLookup())
        let withLocalized = candidates(for: key, digest: FakeDigestLookup(localized: [identifier]))

        let first = AssetCacheKey(for: key, candidates: withoutLocalized)
        let second = AssetCacheKey(for: key, candidates: withLocalized)
        #expect(first != second)
    }

    @Test("Distinct locales never produce the same key, even when candidates happen to coincide")
    func distinctLocaleProducesDistinctKey() throws {
        let identifier = try AssetIdentifier.cardCode("01001b")
        let englishKey = AssetKey(category: .card(.art, identifier), locale: .english)
        let italianKey = AssetKey(category: .card(.art, identifier), locale: .italian)
        // Both resolve to the same single candidate (no localized art for
        // this identifier), yet the keys must still differ.
        let candidateList = candidates(for: englishKey)

        let englishCacheKey = AssetCacheKey(for: englishKey, candidates: candidateList)
        let italianCacheKey = AssetCacheKey(for: italianKey, candidates: candidateList)
        #expect(englishCacheKey != italianCacheKey)
    }

    @Test("The digest hex is safe to use as a filename: lowercase hex only")
    func digestHexIsLowercaseHexOnly() throws {
        let identifier = try AssetIdentifier.cardCode("01001")
        let key = AssetKey(category: .card(.art, identifier))
        let cacheKey = AssetCacheKey(for: key, candidates: candidates(for: key))
        #expect(cacheKey.digestHex.count == 64)
        #expect(cacheKey.digestHex.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
    }
}
