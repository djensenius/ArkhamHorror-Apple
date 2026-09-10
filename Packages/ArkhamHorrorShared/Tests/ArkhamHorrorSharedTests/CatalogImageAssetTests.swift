@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Catalog image asset paths")
struct CatalogImageAssetTests {
    @Test("Catalog paths preserve the web file and deployment prefix exactly", arguments: [
        (LocaleCatalogAssetRole.encounterSet, "encounter-sets/the-gathering.png", AssetFormat.png),
        (.card, "cards/01001.jpeg", .jpeg),
        (.card, "cards/01001.avif", .avif),
        (.token, "tokens/clue.png", .png),
        (.chaosToken, "chaos-tokens/ct-skull.png", .png),
        (.campaign, "campaigns/the-circle-undone.jpg", .jpeg),
        (.homebrew, "homebrew/dark-matter/cards/01001.avif", .avif),
        (.extra, "extra/map.png", .png),
        (.other, "backs/back_encounter.jpg", .jpeg),
    ])
    func exactPaths(role: LocaleCatalogAssetRole, path: String, format: AssetFormat) throws {
        let source = try AssetSourceNamespace(rawAssetBase: "https://cdn.example.test:8443/prefix")
        let image = try #require(CatalogImageAsset(role: role, assetPath: path))
        let key = AssetKey(source: source, category: .catalogImage(image), locale: .french)
        let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        let expectedURL = "https://cdn.example.test:8443/prefix/img/arkham/\(path)"
        #expect(candidate.url(base: source).absoluteString == expectedURL)
        #expect(candidate.canonicalPathComponent == "img/arkham/\(path)")
        #expect(candidate.localeRoot == nil)
        #expect(candidate.format == format)
        #expect(key.expectedFormat == format)
        #expect(!key.category.isLocalizable)
    }

    @Test("Malformed, untrusted, non-canonical and unsupported paths fail closed", arguments: [
        "/img/arkham/encounter-sets/rats.png",
        "img/arkham/encounter-sets/rats.png",
        "https://evil.test/img/arkham/encounter-sets/rats.png",
        "//evil.test/rats.png",
        "encounter-sets/../cards/rats.png",
        "encounter-sets/./rats.png",
        "encounter-sets/%2e%2e/rats.png",
        "encounter-sets/%252e%252e/rats.png",
        "encounter-sets\\rats.png",
        "encounter-sets//rats.png",
        "encounter-sets/rats.png?redirect=evil",
        "encounter-sets/rats.png#fragment",
        "encounter-sets/\nrats.png",
        "encounter-sets/ráts.png",
        "encounter-sets/rats.svg",
        "encounter-sets/rats.webp",
        "encounter-sets/rats.PNG",
        "encounter-sets/.png",
        "encounter-sets/rats.png/",
        "cards/rats.png",
        "rats.png",
        "",
        "encounter-sets/" + String(repeating: "a", count: 249) + ".png",
    ])
    func rejectsPath(_ path: String) {
        #expect(CatalogImageAsset(role: .encounterSet, assetPath: path) == nil)
    }

    @Test("Other is not an arbitrary-root escape hatch and roles cannot impersonate one another")
    func closedRoles() {
        #expect(CatalogImageAsset(role: .other, assetPath: "private/secret.png") == nil)
        #expect(CatalogImageAsset(role: .other, assetPath: "encounter-sets/rats.png") == nil)
        #expect(CatalogImageAsset(role: .homebrew, assetPath: "cards/01001.avif") == nil)
        #expect(LocaleCatalogAssetRole(rawValue: "arbitrary") == nil)
    }

    @Test("Cache authority separates hosts and exact file paths but not catalog locale or alt")
    func cacheIdentity() throws {
        let reference = StoryAssetReference(
            role: .encounterSet, assetPath: "encounter-sets/rats.png", alt: "Rats", source: .hosted
        )
        let key = try #require(reference.assetKey)
        let relabeled = StoryAssetReference(
            role: .encounterSet, assetPath: "encounter-sets/rats.png", alt: "Ratten",
            source: .hosted
        )
        #expect(relabeled.assetKey == reference.assetKey)
        func cacheKey(_ key: AssetKey) -> AssetCacheKey {
            AssetCacheKey(for: key, candidates: AssetLocator.candidates(for: key))
        }
        let otherSource = try AssetSourceNamespace(rawAssetBase: "https://self-hosted.test")
        #expect(cacheKey(key) != cacheKey(AssetKey(source: otherSource, category: key.category)))
        #expect(cacheKey(key) == cacheKey(AssetKey(category: key.category, locale: .french)))
        let oldSetIcon = try AssetKey(category: .setIcon(.setOrBoxCode("01"), variant: nil))
        #expect(cacheKey(key) != cacheKey(oldSetIcon))
    }

    @Test("Alt text and role fallbacks survive presentation without flattening an instruction")
    func accessibilityAndFlow() {
        let reference = StoryAssetReference(
            role: .encounterSet, assetPath: "encounter-sets/rats.png", alt: "Ratten",
            source: .hosted
        )
        let image = StoryNode.image(reference)
        #expect(reference.accessibleDescription == "Ratten")
        #expect(image.losesInstructionWhenFlattened)
        #expect(!StoryNodePresentation.isInline(image))
        #expect(StoryNodePresentation.flow([.text("Sammle "), image, .text(".")]) == [
            .inline([.text("Sammle ")]), .block(image), .inline([.text(".")]),
        ])
        #expect(StoryNodePresentation
            .accessibilityLabel(for: [.text("Sammle "), image]) == "Sammle Ratten")
        let inferred = StoryAssetReference(
            role: .encounterSet, assetPath: "encounter-sets/the-gathering.png",
            alt: nil, source: .hosted
        )
        #expect(inferred.hasMeaningfulAccessibleDescription)
        #expect(inferred.accessibleDescription == "The Gathering encounter set symbol")
        let instructional = StoryAssetReference(
            role: .extra, assetPath: "extra/patrol-layout.png", alt: nil, source: .hosted
        )
        #expect(!instructional.hasMeaningfulAccessibleDescription)
        #expect(instructional.accessibleDescription == "Game image")
        let labels = [
            "Encounter set", "Card image", "Token", "Chaos token",
            "Campaign image", "Homebrew image", "Game image", "Game image",
        ]
        for (role, label) in zip(LocaleCatalogAssetRole.allCases, labels) {
            for alt in [nil, "", " \n"] {
                let fallback = StoryAssetReference(role: role, assetPath: "", alt: alt)
                #expect(fallback.accessibleDescription == label)
                #expect(!fallback.hasMeaningfulAccessibleDescription)
            }
        }
    }
}
