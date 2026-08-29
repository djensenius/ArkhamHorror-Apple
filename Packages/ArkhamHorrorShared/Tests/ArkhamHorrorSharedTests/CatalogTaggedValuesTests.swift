@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Exercises ``CardCost``, ``GameValue``, and ``SkillIcon`` directly (rather than only
/// indirectly through ``CardDef``), focusing on the schema's `additionalProperties: false`
/// nullary-tag cases and unknown-tag forward compatibility.
@Suite("CatalogTaggedValues")
struct CatalogTaggedValuesTests {
    // MARK: - CardCost: known nullary tags reject any "contents" key

    @Test(
        "CardCost's nullary tags reject a present contents key, even null",
        arguments: [
            #"{"tag": "DynamicCost", "contents": null}"#,
            #"{"tag": "DynamicCost", "contents": 1}"#,
            #"{"tag": "DiscardAmountCost", "contents": null}"#,
            #"{"tag": "DeferredCost", "contents": null}"#,
        ]
    )
    func cardCostNullaryTagsRejectContents(json: String) {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(CardCost.self, from: Data(json.utf8))
        }
    }

    @Test(
        "CardCost's nullary tags decode without a contents key",
        arguments: [
            (#"{"tag": "DynamicCost"}"#, CardCost.dynamicCost),
            (#"{"tag": "DiscardAmountCost"}"#, CardCost.discardAmountCost),
            (#"{"tag": "DeferredCost"}"#, CardCost.deferredCost),
        ]
    )
    func cardCostNullaryTagsDecode(json: String, expected: CardCost) throws {
        let decoded = try ContractJSON.decode(CardCost.self, from: Data(json.utf8))
        #expect(decoded == expected)
    }

    @Test("CardCost.unknown preserves the full raw object, including explicit-null contents")
    func cardCostUnknownPreservesExplicitNull() throws {
        let json = #"{"tag": "FutureCost", "contents": null}"#
        let decoded = try ContractJSON.decode(CardCost.self, from: Data(json.utf8))
        #expect(decoded == .unknown(
            tag: "FutureCost",
            rawObject: .object(["tag": .string("FutureCost"), "contents": .null])
        ))
    }

    @Test("CardCost.unknown preserves additive keys beyond tag/contents")
    func cardCostUnknownPreservesAdditiveKeys() throws {
        let json = #"{"tag": "FutureCost", "extra": "value"}"#
        let decoded = try ContractJSON.decode(CardCost.self, from: Data(json.utf8))
        #expect(decoded == .unknown(
            tag: "FutureCost",
            rawObject: .object(["tag": .string("FutureCost"), "extra": .string("value")])
        ))
    }

    @Test("CardCost.unknown cannot be encoded (never resubmittable)")
    func cardCostUnknownCannotEncode() throws {
        let decoded = try ContractJSON.decode(
            CardCost.self,
            from: Data(#"{"tag": "FutureCost"}"#.utf8)
        )
        #expect(throws: CardCostError.cannotEncodeUnknownTag("FutureCost")) {
            try ContractJSON.encode(decoded)
        }
    }

    @Test("A known CardCost tag round-trips through encode/decode")
    func cardCostKnownTagRoundTrips() throws {
        let cost = CardCost.staticCost(3)
        let data = try ContractJSON.encode(cost)
        let redecoded = try ContractJSON.decode(CardCost.self, from: data)
        #expect(redecoded == cost)
    }

    // MARK: - GameValue: ValueX/ValueStar/ValueUnknown reject contents

    @Test(
        "GameValue's nullary tags reject a present contents key, even null",
        arguments: [
            #"{"tag": "ValueX", "contents": null}"#,
            #"{"tag": "ValueStar", "contents": null}"#,
            #"{"tag": "ValueUnknown", "contents": null}"#,
            #"{"tag": "ValueX", "contents": 1}"#,
        ]
    )
    func gameValueNullaryTagsRejectContents(json: String) {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(GameValue.self, from: Data(json.utf8))
        }
    }

    @Test("GameValue.unknown preserves the full raw object")
    func gameValueUnknownPreservesFullPayload() throws {
        let json = #"{"tag": "FutureValue", "contents": [1, 2], "extra": true}"#
        let decoded = try ContractJSON.decode(GameValue.self, from: Data(json.utf8))
        #expect(decoded == .unknown(
            tag: "FutureValue",
            rawObject: .object([
                "tag": .string("FutureValue"),
                "contents": .array([.number(.integer(1)), .number(.integer(2))]),
                "extra": .bool(true),
            ])
        ))
    }

    @Test("GameValue.unknown cannot be encoded")
    func gameValueUnknownCannotEncode() throws {
        let decoded = try ContractJSON.decode(
            GameValue.self,
            from: Data(#"{"tag": "FutureValue"}"#.utf8)
        )
        #expect(throws: GameValueError.cannotEncodeUnknownTag("FutureValue")) {
            try ContractJSON.encode(decoded)
        }
    }

    // MARK: - SkillIcon: WildIcon/WildMinusIcon reject contents

    @Test(
        "SkillIcon's nullary tags reject a present contents key, even null",
        arguments: [
            #"{"tag": "WildIcon", "contents": null}"#,
            #"{"tag": "WildMinusIcon", "contents": null}"#,
            #"{"tag": "WildIcon", "contents": "SkillCombat"}"#,
        ]
    )
    func skillIconNullaryTagsRejectContents(json: String) {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(SkillIcon.self, from: Data(json.utf8))
        }
    }

    @Test("SkillIcon.unknown preserves the full raw object")
    func skillIconUnknownPreservesFullPayload() throws {
        let json = #"{"tag": "FutureIcon"}"#
        let decoded = try ContractJSON.decode(SkillIcon.self, from: Data(json.utf8))
        let expected = JSONValue.object(["tag": .string("FutureIcon")])
        #expect(decoded == .unknown(tag: "FutureIcon", rawObject: expected))
    }

    @Test("SkillIcon.unknown cannot be encoded")
    func skillIconUnknownCannotEncode() throws {
        let decoded = try ContractJSON.decode(
            SkillIcon.self,
            from: Data(#"{"tag": "FutureIcon"}"#.utf8)
        )
        #expect(throws: SkillIconError.cannotEncodeUnknownTag("FutureIcon")) {
            try ContractJSON.encode(decoded)
        }
    }

    // MARK: - GameState: IsActive/IsOver reject contents

    @Test(
        "GameState's nullary tags reject a present contents key, even null",
        arguments: [
            #"{"tag": "IsActive", "contents": null}"#,
            #"{"tag": "IsOver", "contents": null}"#,
            #"{"tag": "IsActive", "contents": []}"#,
        ]
    )
    func gameStateNullaryTagsRejectContents(json: String) {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(GameState.self, from: Data(json.utf8))
        }
    }

    @Test("GameState's nullary tags decode without a contents key")
    func gameStateNullaryTagsDecode() throws {
        let activeJSON = Data(#"{"tag": "IsActive"}"#.utf8)
        let overJSON = Data(#"{"tag": "IsOver"}"#.utf8)
        #expect(try ContractJSON.decode(GameState.self, from: activeJSON) == .active)
        #expect(try ContractJSON.decode(GameState.self, from: overJSON) == .over)
    }

    @Test("GameState.unknown preserves the full raw object")
    func gameStateUnknownPreservesFullPayload() throws {
        let json = #"{"tag": "IsPaused", "reason": "maintenance"}"#
        let decoded = try ContractJSON.decode(GameState.self, from: Data(json.utf8))
        #expect(decoded == .unknown(
            tag: "IsPaused",
            rawObject: .object(["tag": .string("IsPaused"), "reason": .string("maintenance")])
        ))
    }

    @Test("GameState.unknown cannot be encoded")
    func gameStateUnknownCannotEncode() throws {
        let decoded = try ContractJSON.decode(
            GameState.self,
            from: Data(#"{"tag": "IsPaused"}"#.utf8)
        )
        #expect(throws: GameStateError.cannotEncodeUnknownTag("IsPaused")) {
            try ContractJSON.encode(decoded)
        }
    }

    @Test("GameState's IsPending/IsChooseDecks still decode and round-trip their player list")
    func gameStatePendingRoundTrips() throws {
        let id = "00000000-0000-0000-0000-000000000001"
        let json = #"{"tag": "IsPending", "contents": ["\#(id)"]}"#
        let decoded = try ContractJSON.decode(GameState.self, from: Data(json.utf8))
        guard case let .pending(players) = decoded else {
            Issue.record("Expected .pending, got \(decoded)")
            return
        }
        #expect(players.map(\.description) == [id])
        let reencoded = try ContractJSON.encode(decoded)
        let redecoded = try ContractJSON.decode(GameState.self, from: reencoded)
        #expect(redecoded == decoded)
    }
}
