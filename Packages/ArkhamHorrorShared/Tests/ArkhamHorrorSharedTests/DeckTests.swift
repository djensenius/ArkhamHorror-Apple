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
            Bundle.module.url(
                forResource: "decks",
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try ContractJSON.decode(DecksFixture.self, from: Data(contentsOf: url))
    }

    // MARK: - Fixture decode: representative fields

    @Test("createDeck decodes its external deckId and nested permissive deckList")
    func createDeckRequest() throws {
        let fixture = try loadFixture()
        #expect(fixture.createDeck.deckId == "external-4242")
        #expect(fixture.createDeck.deckName == "Contract deck")
        #expect(fixture.createDeck.deckList.id == .number(.integer(4242)))
        #expect(fixture.createDeck.deckList.investigatorCode.rawValue == "01001")
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
        #expect(fixture.validateDeckList.investigatorCode.rawValue == "01001")
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
        #expect(try fixture.validationErrors.elements == [.unimplementedCard(CardCode("c99999"))])
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
            try ContractJSON.decode(ExternalID.self, from: Data(json.utf8))
        }
        #expect(try decode(#""4242""#) == .string("4242"))
        #expect(try decode("4242") == .number(.integer(4242)))
        #expect(try decode("null") == .null)
    }

    @Test("ExternalID decodes a fractional number losslessly as .decimal")
    func externalIDDecimalVariant() throws {
        let decoded = try ContractJSON.decode(ExternalID.self, from: Data("4242.5".utf8))
        #expect(try decoded == .number(.decimal(#require(Decimal(string: "4242.5")))))
    }

    @Test("ExternalID beyond Decimal's ~38 significant digits round-trips exactly via ContractJSON")
    func externalIDLargeIntegerIsLosslessThroughContractJSON() throws {
        // 45 nines: more significant digits than Decimal's ~38-digit budget can hold exactly.
        let literal = String(repeating: "9", count: 45)
        let json = #"{"slots": {"x": 1}, "investigator_code": "01001", "id": \#(literal)}"#
        let input = try ContractJSON.decode(DeckListInput.self, from: Data(json.utf8))
        guard case let .number(number) = input.id else {
            Issue.record("Expected a .number ExternalID, got \(String(describing: input.id))")
            return
        }
        #expect(number.coefficient == literal)
        let reencoded = try ContractJSON.encode(input)
        let reencodedText = try #require(String(data: reencoded, encoding: .utf8))
        #expect(reencodedText.contains(literal))
    }

    @Test("The same 45-nines ExternalID is silently rounded by a stock JSONDecoder")
    func externalIDLargeIntegerIsLossyThroughStockDecoder() throws {
        let literal = String(repeating: "9", count: 45)
        let json = #"{"slots": {"x": 1}, "investigator_code": "01001", "id": \#(literal)}"#
        // Deliberately the stock `JSONDecoder`, not `ContractJSON.decode`: this test exists
        // specifically to prove that bypassing the lossless codec really does reintroduce
        // numeric loss, contrasting with `externalIDLargeIntegerIsLosslessThroughContractJSON`
        // immediately above. Every other test in this file uses `ContractJSON` deliberately.
        let input = try JSONDecoder().decode(DeckListInput.self, from: Data(json.utf8))
        guard case let .number(number) = input.id else {
            Issue.record("Expected a .number ExternalID, got \(String(describing: input.id))")
            return
        }
        // Decimal's ~38 significant digits cannot hold all 45 nines exactly: this proves
        // the stock-`Decoder` fallback path really is lossy here, unlike ContractJSON,
        // which is the entire point of routing contract decoding through it.
        #expect(number.coefficient != literal)
    }

    @Test("DeckListInput.id distinguishes absent, explicit null, and a present value")
    func deckListInputIDTriState() throws {
        func decode(_ json: String) throws -> ExternalID? {
            try ContractJSON.decode(DeckListInput.self, from: Data(json.utf8)).id
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
        let input = try ContractJSON.decode(DeckListInput.self, from: Data(json.utf8))
        #expect(input.sideSlots == .absent)
    }

    @Test("sideSlots as a valid card-quantity object decodes to .valid")
    func sideSlotsValid() throws {
        let json = """
        {"slots": {"x": 1}, "investigator_code": "01001", "sideSlots": {"c01016": 1}}
        """
        let input = try ContractJSON.decode(DeckListInput.self, from: Data(json.utf8))
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
        let input = try ContractJSON.decode(DeckListInput.self, from: Data(json.utf8))
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
            try ContractJSON.decode(DeckListInput.self, from: ContractJSON.encode(input))
        }
        let base = try DeckListInput(
            slots: CardQuantityMapInput(["x": 1]),
            sideSlots: .absent,
            investigatorCode: InvestigatorCode("01001"),
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
}
