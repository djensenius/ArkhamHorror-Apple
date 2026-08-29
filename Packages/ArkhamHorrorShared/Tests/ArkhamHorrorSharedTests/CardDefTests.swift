@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Mirrors `contracts/fixtures/catalog.json`'s combined shape. No production endpoint
/// returns this combined shape; each key matches an independent endpoint's own response
/// type, decoded here for fixture-based testing convenience only.
private struct CatalogFixture: Decodable {
    let cards: CardList
    let homebrewCards: CardList
    let card: CardDef
    let investigators: InvestigatorArtwork
}

@Suite("CardDef")
struct CardDefTests {
    private func loadFixture() throws -> CatalogFixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "catalog",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try JSONDecoder().decode(CatalogFixture.self, from: Data(contentsOf: url))
    }

    // MARK: - Fixture decode: representative fields

    @Test("The player asset card (Machete) decodes its representative fields")
    func playerAssetCard() throws {
        let fixture = try loadFixture()
        let machete = try #require(fixture.cards.first)
        #expect(machete.cardCode.rawValue == "c01020")
        #expect(machete.name == CardName(title: "Machete", subtitle: nil))
        #expect(machete.cost == .staticCost(3))
        #expect(machete.level == 0)
        #expect(machete.cardType == .asset)
        #expect(machete.classSymbols == [.guardian])
        #expect(machete.skills == [.skill(.combat)])
        #expect(machete.cardTraits == ["Item", "Melee", "Weapon"])
        #expect(machete.slots == [.hand])
        #expect(machete.alternateCardCodes?.map(\.rawValue) == ["c01520", "c12020"])
        #expect(machete.art == "01020")
        #expect(machete.alternateErrata?["c12020"]?.contains("succeed") == true)
        // Every field the fixture doesn't set stays nil, not a default sentinel.
        #expect(machete.revealedName == nil)
        #expect(machete.health == nil)
        #expect(machete.meta == nil)
    }

    @Test("The homebrew enemy card decodes its game values and homebrew-shaped code")
    func homebrewEnemyCard() throws {
        let fixture = try loadFixture()
        let rats = try #require(fixture.homebrewCards.first)
        #expect(rats.cardCode.rawValue == "c:dark-matter:151")
        #expect(rats.cardType == .enemy)
        #expect(rats.cardTraits == ["Creature", "Monster"])
        #expect(rats.encounterSet == ":dark-matter:in_the_shadow_of_earth")
        #expect(rats.encounterSetQuantity == 3)
        #expect(rats.health == .staticValue(1))
        #expect(rats.fight == .staticValue(1))
        #expect(rats.evade == .staticValue(3))
        #expect(rats.healthDamage == .staticValue(1))
        #expect(rats.sanityDamage == nil)
    }

    @Test("The singular investigator card decodes with a nullable subtitle present")
    func investigatorCard() throws {
        let fixture = try loadFixture()
        #expect(fixture.card.cardCode.rawValue == "c01001")
        #expect(fixture.card.name == CardName(title: "Roland Banks", subtitle: "The Fed"))
        #expect(fixture.card.cardType == .investigator)
        #expect(fixture.card.unique == true)
        #expect(fixture.card.alternateCardCodes?.map(\.rawValue) == ["c01501", "c98004"])
    }

    @Test("investigatorArtwork decodes as a plain list of card codes")
    func investigatorArtwork() throws {
        let fixture = try loadFixture()
        #expect(fixture.investigators == ["01001", "01002"])
    }

    // MARK: - Malformed / missing / wrong-type inputs

    @Test("A malformed cardCode throws DecodingError")
    func malformedCardCodeThrows() {
        let json = """
        {"cardCode": "01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020"}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        }
    }

    @Test("A missing required field (art) throws DecodingError")
    func missingRequiredFieldThrows() {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType"}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        }
    }

    @Test("A wrong scalar type for a strongly typed field (level as a string) throws")
    func wrongScalarTypeThrows() {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020", "level": "zero"}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        }
    }

    @Test("An unknown additive top-level key is ignored")
    func unknownAdditiveFieldIgnored() throws {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020", "somethingFromTheFuture": 123}
        """
        let card = try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        #expect(card.cardCode.rawValue == "c01020")
    }

    // MARK: - Tagged union forward compatibility

    @Test("An unrecognized cardCost tag decodes to .unknown, not a decode failure")
    func unknownCardCostTag() throws {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020",
         "cost": {"tag": "FutureCost", "contents": {"future": true}}}
        """
        let card = try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        #expect(
            card.cost == .unknown(tag: "FutureCost", contents: .object(["future": .bool(true)]))
        )
    }

    @Test("An unrecognized gameValue tag decodes to .unknown")
    func unknownGameValueTag() throws {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020",
         "health": {"tag": "FutureValue"}}
        """
        let card = try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        #expect(card.health == .unknown(tag: "FutureValue", contents: nil))
    }

    @Test("An unrecognized skillIcon tag decodes to .unknown")
    func unknownSkillIconTag() throws {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020",
         "skills": [{"tag": "FutureIcon"}]}
        """
        let card = try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        #expect(card.skills == [.unknown(tag: "FutureIcon", contents: nil)])
    }

    @Test("GameValue's StaticWithPerPlayer and ByPlayerCount decode their fixed-size arrays")
    func gameValueArrayVariants() throws {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020",
         "health": {"tag": "StaticWithPerPlayer", "contents": [1, 2]},
         "fight": {"tag": "ByPlayerCount", "contents": [1, 2, 3, 4]}}
        """
        let card = try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        #expect(card.health == .staticWithPerPlayer(1, 2))
        #expect(card.fight == .byPlayerCount(1, 2, 3, 4))
    }

    @Test("bondedWith decodes its 2-element [count, cardCode] tuples")
    func bondedWithTuples() throws {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020",
         "bondedWith": [[2, "c01021"]]}
        """
        let card = try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        #expect(try card.bondedWith == [BondedCardEntry(count: 2, cardCode: CardCode("c01021"))])
        let reencoded = try JSONEncoder().encode(card.bondedWith)
        let redecoded = try JSONDecoder().decode([BondedCardEntry].self, from: reencoded)
        #expect(redecoded == card.bondedWith)
    }

    @Test("Encoding a decoded CardDef round-trips through decoding")
    func encodeDecodeRoundTrip() throws {
        let fixture = try loadFixture()
        let machete = try #require(fixture.cards.first)
        let data = try JSONEncoder().encode(machete)
        let redecoded = try JSONDecoder().decode(CardDef.self, from: data)
        #expect(redecoded == machete)
    }
}
