@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Mirrors `contracts/fixtures/decks.json`'s combined shape. No production endpoint returns
/// this combined shape; each key matches an independent endpoint's own request/response
/// type, decoded here for fixture-based testing convenience only.
private struct DecksFixture: Decodable {
    let createDeck: CreateDeckRequest
    let fetchDeck: FetchDeckRequest
    let validateDeckList: DeckListInput
    let normalizedDeckList: DeckList
    let deck: Deck
    let validationErrors: DeckValidationErrors
    let validationSuccess: DeckValidationSuccess
    let operationError: DeckOperationError
}

@Suite("Deck")
struct DeckTests {
    private func loadFixture() throws -> DecksFixture {
        let url = try #require(
            Bundle.module.url(forResource: "decks", withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONDecoder().decode(DecksFixture.self, from: Data(contentsOf: url))
    }

    // MARK: - Fixture decode: representative fields

    @Test("createDeck decodes its external deckId and nested permissive deckList")
    func createDeckRequest() throws {
        let fixture = try loadFixture()
        #expect(fixture.createDeck.deckId == "external-4242")
        #expect(fixture.createDeck.deckName == "Contract deck")
        #expect(fixture.createDeck.deckList.id == .number(.integer(4242)))
        #expect(fixture.createDeck.deckList.investigatorCode == "01001")
        #expect(fixture.createDeck.deckList.slots.quantities == ["01016": 2, "c01018": 1])
        if case let .malformed(.array(items)) = fixture.createDeck.deckList.sideSlots {
            #expect(items.isEmpty)
        } else {
            let message = "Expected sideSlots to be malformed(.array([])), got "
                + "\(fixture.createDeck.deckList.sideSlots)"
            Issue.record("\(message)")
        }
    }

    @Test("fetchDeck decodes its url")
    func fetchDeckRequest() throws {
        let fixture = try loadFixture()
        #expect(fixture.fetchDeck.url == "https://arkhamdb.com/decklist/view/4242")
    }

    @Test("validateDeckList ignores its unknown additive externalField")
    func validateDeckListIgnoresUnknownField() throws {
        let fixture = try loadFixture()
        #expect(fixture.validateDeckList.investigatorCode == "01001")
        #expect(fixture.validateDeckList.tabooId == nil)
    }

    @Test("normalizedDeckList decodes validated CardCode keys and a numeric-turned-string id")
    func normalizedDeckList() throws {
        let fixture = try loadFixture()
        let expectedSlots = try [CardCode("c01016"): 2, CardCode("c01018"): 1]
        #expect(fixture.normalizedDeckList.slots.quantities == expectedSlots)
        #expect(fixture.normalizedDeckList.sideSlots.quantities.isEmpty)
        #expect(fixture.normalizedDeckList.investigatorCode.rawValue == "c01001")
        #expect(fixture.normalizedDeckList.id == "4242.0")
    }

    @Test("deck decodes its UUID id and nested normalized list")
    func deck() throws {
        let fixture = try loadFixture()
        #expect(fixture.deck.id.rawValue.uuidString == "00000000-0000-0000-0000-000000000017")
        #expect(fixture.deck.userId == 7)
        #expect(fixture.deck.investigatorName == "Roland Banks")
        #expect(fixture.deck.list.investigatorCode.rawValue == "c01001")
    }

    @Test("validationErrors decodes the known UnimplementedCard tag")
    func validationErrors() throws {
        let fixture = try loadFixture()
        #expect(try fixture.validationErrors == [.unimplementedCard(CardCode("c99999"))])
    }

    @Test("validationSuccess decodes the always-empty marker")
    func validationSuccess() throws {
        let fixture = try loadFixture()
        #expect(fixture.validationSuccess == DeckValidationSuccess())
    }

    @Test("operationError decodes its message")
    func operationError() throws {
        let fixture = try loadFixture()
        #expect(fixture.operationError.errorMsg == "Could not sync deck")
    }

    // MARK: - ExternalID: mixed deck ID types

    @Test("ExternalID decodes a string, an integer, and an explicit null")
    func externalIDVariants() throws {
        func decode(_ json: String) throws -> ExternalID {
            try JSONDecoder().decode(ExternalID.self, from: Data(json.utf8))
        }
        #expect(try decode(#""4242""#) == .string("4242"))
        #expect(try decode("4242") == .number(.integer(4242)))
        #expect(try decode("null") == .null)
    }

    @Test("ExternalID decodes a fractional number losslessly as .decimal")
    func externalIDDecimalVariant() throws {
        let decoded = try JSONDecoder().decode(ExternalID.self, from: Data("4242.5".utf8))
        #expect(try decoded == .number(.decimal(#require(Decimal(string: "4242.5")))))
    }

    @Test("DeckListInput.id distinguishes absent, explicit null, and a present value")
    func deckListInputIDTriState() throws {
        func decode(_ json: String) throws -> ExternalID? {
            try JSONDecoder().decode(DeckListInput.self, from: Data(json.utf8)).id
        }
        let base = #"{"slots": {"x": 1}, "investigator_code": "01001""#
        #expect(try decode(base + "}") == nil)
        #expect(try decode(base + #", "id": null}"#) == .some(.null))
        #expect(try decode(base + #", "id": 42}"#) == .some(.number(.integer(42))))
        #expect(try decode(base + #", "id": "abc"}"#) == .some(.string("abc")))
    }

    // MARK: - sideSlots: malformed vs valid vs absent

    @Test("sideSlots absent decodes to .absent")
    func sideSlotsAbsent() throws {
        let json = #"{"slots": {"x": 1}, "investigator_code": "01001"}"#
        let input = try JSONDecoder().decode(DeckListInput.self, from: Data(json.utf8))
        #expect(input.sideSlots == .absent)
    }

    @Test("sideSlots as a valid card-quantity object decodes to .valid")
    func sideSlotsValid() throws {
        let json = """
        {"slots": {"x": 1}, "investigator_code": "01001", "sideSlots": {"c01016": 1}}
        """
        let input = try JSONDecoder().decode(DeckListInput.self, from: Data(json.utf8))
        #expect(input.sideSlots == .valid(CardQuantityMapInput(["c01016": 1])))
    }

    @Test(
        "sideSlots as a non-object value decodes to .malformed, preserving the raw payload",
        arguments: ["[]", "42", "\"oops\"", "null"]
    )
    func sideSlotsMalformed(rawSideSlots: String) throws {
        let json = """
        {"slots": {"x": 1}, "investigator_code": "01001", "sideSlots": \(rawSideSlots)}
        """
        let input = try JSONDecoder().decode(DeckListInput.self, from: Data(json.utf8))
        guard case .malformed = input.sideSlots else {
            Issue.record(
                "Expected .malformed for raw sideSlots \(rawSideSlots), got \(input.sideSlots)"
            )
            return
        }
    }

    @Test("DeckListInput encode round-trips absent/valid/malformed sideSlots exactly")
    func sideSlotsEncodeRoundTrip() throws {
        func roundTrip(_ input: DeckListInput) throws -> DeckListInput {
            try JSONDecoder().decode(DeckListInput.self, from: JSONEncoder().encode(input))
        }
        let base = DeckListInput(
            slots: CardQuantityMapInput(["x": 1]),
            sideSlots: .absent,
            investigatorCode: "01001",
            investigatorName: nil,
            meta: nil,
            tabooId: nil,
            url: nil,
            id: nil,
            name: nil
        )
        #expect(try roundTrip(base).sideSlots == .absent)

        let withValid = DeckListInput(
            slots: base.slots,
            sideSlots: .valid(CardQuantityMapInput(["c01016": 2])),
            investigatorCode: base.investigatorCode,
            investigatorName: nil, meta: nil, tabooId: nil, url: nil, id: nil, name: nil
        )
        #expect(try roundTrip(withValid).sideSlots == withValid.sideSlots)

        let withMalformed = DeckListInput(
            slots: base.slots,
            sideSlots: .malformed(.array([])),
            investigatorCode: base.investigatorCode,
            investigatorName: nil, meta: nil, tabooId: nil, url: nil, id: nil, name: nil
        )
        #expect(try roundTrip(withMalformed).sideSlots == withMalformed.sideSlots)
    }

    // MARK: - Card quantity map key validation

    @Test("CardQuantityMapInput rejects an empty-string key")
    func cardQuantityMapInputRejectsEmptyKey() {
        let json = #"{"": 1}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CardQuantityMapInput.self, from: Data(json.utf8))
        }
    }

    @Test("CardQuantityMapInput accepts nonempty opaque keys without a 'c' prefix")
    func cardQuantityMapInputAcceptsOpaqueKeys() throws {
        let decoded = try JSONDecoder().decode(
            CardQuantityMapInput.self,
            from: Data(#"{"01016": 2, "c01018": 1}"#.utf8)
        )
        #expect(decoded.quantities == ["01016": 2, "c01018": 1])
    }

    @Test("CardQuantityMap rejects a key without the 'c' prefix")
    func cardQuantityMapRejectsInvalidCardCodeKey() {
        let json = #"{"01016": 2}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CardQuantityMap.self, from: Data(json.utf8))
        }
    }

    @Test("CardQuantityMap accepts validated CardCode keys")
    func cardQuantityMapAcceptsValidKeys() throws {
        let decoded = try JSONDecoder().decode(
            CardQuantityMap.self,
            from: Data(#"{"c01016": 2}"#.utf8)
        )
        #expect(try decoded.quantities[CardCode("c01016")] == 2)
    }

    // MARK: - DeckValidationSuccess strictness

    @Test("DeckValidationSuccess rejects a non-empty array")
    func deckValidationSuccessRejectsNonEmpty() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DeckValidationSuccess.self, from: Data("[1]".utf8))
        }
    }

    @Test("DeckValidationError preserves an unrecognized tag as .unknown")
    func deckValidationErrorUnknownTag() throws {
        let json = #"{"tag": "FutureError", "contents": "details"}"#
        let decoded = try JSONDecoder().decode(DeckValidationError.self, from: Data(json.utf8))
        #expect(decoded == .unknown(tag: "FutureError", contents: .string("details")))
    }

    // MARK: - DeckList: all nine keys always present

    @Test("DeckList rejects a payload missing one of its always-present nullable keys")
    func deckListRejectsMissingNullableKey() {
        let json = """
        {"slots": {}, "sideSlots": {}, "investigator_code": "c01001",
         "investigator_name": "Roland Banks", "meta": null, "taboo_id": null, "url": null,
         "id": null}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DeckList.self, from: Data(json.utf8))
        }
    }

    @Test("DeckList encodes its nil optional fields as explicit null, not an omitted key")
    func deckListEncodesExplicitNull() throws {
        let deckList = try DeckList(
            slots: CardQuantityMap([CardCode("c01016"): 2]),
            sideSlots: CardQuantityMap([:]),
            investigatorCode: CardCode("c01001"),
            investigatorName: "Roland Banks",
            meta: nil,
            tabooId: nil,
            url: nil,
            id: nil,
            name: nil
        )
        let data = try JSONEncoder().encode(deckList)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        for key in ["meta", "taboo_id", "url", "id", "name"] {
            #expect(object[key] is NSNull, "Expected \(key) to be explicit null")
        }
        let redecoded = try JSONDecoder().decode(DeckList.self, from: data)
        #expect(redecoded == deckList)
    }
}
