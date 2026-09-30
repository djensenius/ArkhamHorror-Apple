@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Deck 0.1.46 compatibility")
struct DeckRevision146Tests {
    private struct DecksFixture: Decodable {
        let deck: Deck
    }

    @Test("deck decodes the vendored 0.1.46 fixture with null additive fields")
    func deckDecodesRevision146SyncFixture() throws {
        let url = try #require(Bundle.module.url(
            forResource: "decks",
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        let fixture = try ContractJSON.decode(DecksFixture.self, from: Data(contentsOf: url))
        let deck = fixture.deck
        #expect(deck.lastUsedAt == nil)
        #expect(deck.overlay == nil)
        #expect(deck.playList == deck.list)
    }

    @Test("deck decodes additive 0.1.46 lastUsedAt, overlay, and playList fields")
    func deckDecodesRevision146Fields() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000017",
          "userId": 7,
          "url": null,
          "name": "Contract deck",
          "investigatorName": "Roland Banks",
          "lastUsedAt": "2026-09-29T00:00:00Z",
          "overlay": {"cards": []},
          "list": {
            "slots": {"c01016": 2},
            "sideSlots": {},
            "investigator_code": "c01001",
            "investigator_name": "Roland Banks",
            "meta": null,
            "taboo_id": null,
            "url": null,
            "id": "4242.0",
            "name": "Contract deck"
          },
          "playList": {
            "slots": {"c01016": 1, "c01018": 1},
            "sideSlots": {},
            "investigator_code": "c01001",
            "investigator_name": "Roland Banks",
            "meta": null,
            "taboo_id": null,
            "url": null,
            "id": "4242.0",
            "name": "Contract deck"
          }
        }
        """
        let deck = try ContractJSON.decode(Deck.self, from: Data(json.utf8))
        #expect(deck.lastUsedAt == "2026-09-29T00:00:00Z")
        #expect(deck.overlay == .object(["cards": .array([])]))
        #expect(deck.playList?.slots.quantities.count == 2)
        #expect(deck.playableList == deck.playList)
    }
}
