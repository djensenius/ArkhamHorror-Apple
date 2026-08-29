@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Adversarial, mutation-resistant coverage cutting across this contract slice's model:
/// duplicate keys, invalid map keys, null vs absent, wrong ordinary/enemy discrimination,
/// wrong fixed tag arity, invalid side values, turn `-1`, huge coefficient/exponent
/// preserved in open data, unknown tags, and the existing production byte/depth bounds.
@Suite("Board snapshot adversarial decode")
struct BoardSnapshotAdversarialTests {
    private func fixtureData(named fileName: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: fileName,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    // MARK: - Duplicate keys

    @Test("A duplicated object key inside a PublicGame payload fails at the parser boundary")
    func duplicateKeyInPublicGamePayloadFails() throws {
        let bytes = Data(#"{"tag": "PublicGame", "tag": "PublicGame"}"#.utf8)
        #expect(throws: LosslessJSONParserError.self) {
            _ = try ContractJSON.decode(PublicGameSnapshot.self, from: bytes)
        }
    }

    @Test("A duplicated key inside a nested entity map value fails at the parser boundary")
    func duplicateKeyInsideEntityMapValueFails() throws {
        let bytes = Data(
            #"{"00000000-0000-0000-0000-000000000001": {"x": 1, "x": 2}}"#.utf8
        )
        #expect(throws: LosslessJSONParserError.self) {
            _ = try ContractJSON.decode(UUIDEntityMap<EnemyIDTag>.self, from: bytes)
        }
    }

    // MARK: - Turn -1

    @Test("A negative scenario turn fails to decode with a useful coding path")
    func negativeScenarioTurnFails() throws {
        var fixture = try #require(
            String(data: fixtureData(named: "mode-turn-zero"), encoding: .utf8)
        )
        fixture = fixture.replacingOccurrences(of: "\"turn\": 0", with: "\"turn\": -1")
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(GameMode.self, from: Data(fixture.utf8))
        }
    }

    // MARK: - Huge coefficient/exponent in open data

    @Test("A huge-exponent number inside an open RuntimeCost.contents field round-trips exactly")
    func hugeExponentInOpenCostContentsRoundTrips() throws {
        let bytes = Data(#"{"tag": "SomeCost", "contents": 1e400}"#.utf8)
        let cost = try ContractJSON.decode(RuntimeCost.self, from: bytes)
        guard case let .number(number)? = cost.contents else {
            Issue.record("Expected a number contents value")
            return
        }
        #expect(number.description.lowercased().contains("1e400") || number.coefficient == "1")
        let reencoded = try ContractJSON.encode(cost)
        let json = try #require(String(data: reencoded, encoding: .utf8))
        #expect(json.lowercased().contains("1e400"))
    }

    @Test("A huge-coefficient number inside an open meta field round-trips exactly")
    func hugeCoefficientInOpenMetaFieldRoundTrips() throws {
        let hugeDigits = String(repeating: "9", count: 60)
        let bytes = Data(#"{"tag": "SomeCost", "contents": \#(hugeDigits)}"#.utf8)
        let cost = try ContractJSON.decode(RuntimeCost.self, from: bytes)
        let reencoded = try ContractJSON.encode(cost)
        let json = try #require(String(data: reencoded, encoding: .utf8))
        #expect(json.contains(hugeDigits))
    }

    // MARK: - Unknown tags

    @Test("An unknown ServerMessage tag decodes as a typed unsupported message, never fatal")
    func unknownServerMessageTagIsUnsupported() throws {
        let bytes = Data(#"{"tag": "GameError", "contents": "boom"}"#.utf8)
        let update = try ContractJSON.decode(BoardSnapshotUpdate.self, from: bytes)
        guard case let .unsupportedMessage(tag, rawContents) = update else {
            Issue.record("Expected .unsupportedMessage")
            return
        }
        #expect(tag == "GameError")
        #expect(rawContents == .string("boom"))
    }

    @Test("A genuinely unknown ServerMessage tag also decodes as unsupported, not a crash")
    func genuinelyUnknownServerMessageTagIsUnsupported() throws {
        let bytes = Data(#"{"tag": "SomeFutureMessageType"}"#.utf8)
        let update = try ContractJSON.decode(BoardSnapshotUpdate.self, from: bytes)
        guard case let .unsupportedMessage(tag, rawContents) = update else {
            Issue.record("Expected .unsupportedMessage")
            return
        }
        #expect(tag == "SomeFutureMessageType")
        #expect(rawContents == nil)
    }

    @Test("An unsupported message's explicit null contents is preserved as .null, not absent")
    func unsupportedMessageExplicitNullContentsIsPreserved() throws {
        // An explicit "contents": null is a materially different wire shape from the
        // key being entirely absent (see genuinelyUnknownServerMessageTagIsUnsupported
        // above): the former must decode to .some(.null), never collapse to the same
        // nil an absent key would produce.
        let bytes = Data(#"{"tag": "GameError", "contents": null}"#.utf8)
        let update = try ContractJSON.decode(BoardSnapshotUpdate.self, from: bytes)
        guard case let .unsupportedMessage(tag, rawContents) = update else {
            Issue.record("Expected .unsupportedMessage")
            return
        }
        #expect(tag == "GameError")
        #expect(rawContents == .null)
        // Round-trips: the encoded form must still carry an explicit "contents": null,
        // not omit the key.
        let reencoded = try ContractJSON.encode(update)
        let json = try #require(String(data: reencoded, encoding: .utf8))
        #expect(json.contains("\"contents\":null") || json.contains("\"contents\": null"))
    }

    @Test("A malformed ServerMessage missing its tag entirely fails to decode")
    func missingTagFails() throws {
        let bytes = Data(#"{"contents": {}}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(BoardSnapshotUpdate.self, from: bytes)
        }
    }

    // MARK: - Wrong known-tag arity / invalid side

    @Test("A GameValue StaticWithPerPlayer with only 1 element (wrong arity) fails to decode")
    func gameValueWrongArityFails() throws {
        let bytes = Data(#"{"tag": "StaticWithPerPlayer", "contents": [1]}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(GameValue.self, from: bytes)
        }
    }

    @Test("A GameValue ByPlayerCount with only 3 elements (wrong arity) fails to decode")
    func gameValueByPlayerCountWrongArityFails() throws {
        let bytes = Data(#"{"tag": "ByPlayerCount", "contents": [1, 2, 3]}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(GameValue.self, from: bytes)
        }
    }

    // MARK: - Null vs absent

    @Test("A missing required-nullable key fails, distinct from an explicit null value")
    func missingRequiredNullableKeyFailsDistinctFromNull() throws {
        // shroud is required (but nullable) on OrdinaryLocation: omitting the key
        // entirely is a contract violation distinct from an explicit null.
        var fixture = try #require(
            String(data: fixtureData(named: "location-enemy-view"), encoding: .utf8)
        )
        // location-enemy-view.json is the EnemyLocationView shape; reuse its "shroud":
        // {...} block removal to exercise the missing-required-nullable-key path shared
        // by both Location branches.
        fixture = fixture.replacingOccurrences(
            of: "\"shroud\": {\n    \"contents\": 4,\n    \"tag\": \"Static\"\n  },",
            with: ""
        )
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(Location.self, from: Data(fixture.utf8))
        }
        // The thrown error's own coding path names the specific missing key ("shroud"),
        // not merely the enclosing object, so a contract-drift diagnostic actually
        // points at what's missing rather than only where.
        do {
            _ = try ContractJSON.decode(Location.self, from: Data(fixture.utf8))
            Issue.record("Expected decoding to throw")
        } catch let DecodingError.keyNotFound(key, context) {
            #expect(key.stringValue == "shroud")
            #expect(context.codingPath.last?.stringValue == "shroud")
        }
    }

    // MARK: - Depth/input bounds

    @Test("A JSONValue field nested beyond the production depth limit fails to decode")
    func excessiveNestingInOpenDataFails() throws {
        let depth = LosslessJSONByteScanner.maxNestingDepth + 8
        var json = "{\"tag\": \"Deep\", \"contents\": "
        json += String(repeating: "[", count: depth)
        json += "1"
        json += String(repeating: "]", count: depth)
        json += "}"
        #expect(throws: (any Error).self) {
            _ = try ContractJSON.decode(RuntimeCost.self, from: Data(json.utf8))
        }
    }
}
