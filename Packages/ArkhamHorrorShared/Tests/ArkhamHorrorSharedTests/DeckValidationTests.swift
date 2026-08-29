@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Split out of ``DeckTests`` purely to stay under SwiftLint's file/type length
/// limits: covers card-quantity-map key validation, `DeckValidationSuccess`/
/// `DeckValidationErrors` strictness (issue #8), and `DeckList`'s always-present
/// nullable keys (issue #3).
@Suite("Deck quantity map validation and DeckList always-present keys")
struct DeckValidationTests {
    // MARK: - Card quantity map key validation

    @Test("CardQuantityMapInput rejects an empty-string key")
    func cardQuantityMapInputRejectsEmptyKey() {
        let json = #"{"": 1}"#
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(CardQuantityMapInput.self, from: Data(json.utf8))
        }
    }

    @Test("CardQuantityMapInput accepts nonempty opaque keys without a 'c' prefix")
    func cardQuantityMapInputAcceptsOpaqueKeys() throws {
        let decoded = try ContractJSON.decode(
            CardQuantityMapInput.self,
            from: Data(#"{"01016": 2, "c01018": 1}"#.utf8)
        )
        #expect(decoded.quantities == ["01016": 2, "c01018": 1])
    }

    @Test("CardQuantityMap rejects a key without the 'c' prefix")
    func cardQuantityMapRejectsInvalidCardCodeKey() {
        let json = #"{"01016": 2}"#
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(CardQuantityMap.self, from: Data(json.utf8))
        }
    }

    @Test("CardQuantityMap accepts validated CardCode keys")
    func cardQuantityMapAcceptsValidKeys() throws {
        let decoded = try ContractJSON.decode(
            CardQuantityMap.self,
            from: Data(#"{"c01016": 2}"#.utf8)
        )
        #expect(try decoded.quantities[CardCode("c01016")] == 2)
    }

    // MARK: - DeckValidationSuccess strictness

    @Test("DeckValidationSuccess rejects a non-empty array")
    func deckValidationSuccessRejectsNonEmpty() {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(DeckValidationSuccess.self, from: Data("[1]".utf8))
        }
    }

    @Test("DeckValidationErrors rejects an empty array (would-be success shape)")
    func deckValidationErrorsRejectsEmptyArray() {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(DeckValidationErrors.self, from: Data("[]".utf8))
        }
    }

    @Test("DeckValidationErrors accepts a non-empty array")
    func deckValidationErrorsAcceptsNonEmpty() throws {
        let json = #"[{"tag": "UnimplementedCard", "contents": "c99999"}]"#
        let decoded = try ContractJSON.decode(DeckValidationErrors.self, from: Data(json.utf8))
        #expect(try decoded.elements == [.unimplementedCard(CardCode("c99999"))])
    }

    @Test("DeckValidationError rejects a malformed UnimplementedCard contents value")
    func deckValidationErrorRejectsMalformedKnownTag() {
        let json = #"{"tag": "UnimplementedCard", "contents": "no-prefix"}"#
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(DeckValidationError.self, from: Data(json.utf8))
        }
    }

    @Test("DeckValidationError preserves an unrecognized tag as .unsupported with the full payload")
    func deckValidationErrorUnknownTagPreservesFullPayload() throws {
        let json = #"{"tag": "FutureError", "contents": "details", "extra": 1}"#
        let decoded = try ContractJSON.decode(DeckValidationError.self, from: Data(json.utf8))
        guard case let .unsupported(rawObject) = decoded else {
            Issue.record("Expected .unsupported, got \(decoded)")
            return
        }
        #expect(rawObject == .object([
            "tag": .string("FutureError"),
            "contents": .string("details"),
            "extra": .number(.integer(1)),
        ]))
    }

    @Test("DeckValidationError preserves an unrecognized tag's explicit-null contents")
    func deckValidationErrorUnknownTagPreservesExplicitNullContents() throws {
        let json = #"{"tag": "FutureError", "contents": null}"#
        let decoded = try ContractJSON.decode(DeckValidationError.self, from: Data(json.utf8))
        guard case let .unsupported(rawObject) = decoded else {
            Issue.record("Expected .unsupported, got \(decoded)")
            return
        }
        #expect(rawObject == .object(["tag": .string("FutureError"), "contents": .null]))
    }

    @Test("DeckValidationError.unsupported can never be encoded (never resubmittable)")
    func deckValidationErrorUnsupportedCannotEncode() throws {
        let json = #"{"tag": "FutureError"}"#
        let decoded = try ContractJSON.decode(DeckValidationError.self, from: Data(json.utf8))
        #expect(throws: DeckValidationErrorError.cannotEncodeUnsupportedTag) {
            try ContractJSON.encode(decoded)
        }
    }

    @Test("An unrecognized tag is never conflated with .unimplementedCard")
    func deckValidationErrorUnknownTagNeverBecomesUnimplementedCard() throws {
        let json = #"{"tag": "UnimplementedCardV2", "contents": "c99999"}"#
        let decoded = try ContractJSON.decode(DeckValidationError.self, from: Data(json.utf8))
        if case .unimplementedCard = decoded {
            Issue.record("Expected .unsupported, got .unimplementedCard")
        }
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
            try ContractJSON.decode(DeckList.self, from: Data(json.utf8))
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
        let data = try ContractJSON.encode(deckList)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        for key in ["meta", "taboo_id", "url", "id", "name"] {
            #expect(object[key] is NSNull, "Expected \(key) to be explicit null")
        }
        let redecoded = try ContractJSON.decode(DeckList.self, from: data)
        #expect(redecoded == deckList)
    }
}
