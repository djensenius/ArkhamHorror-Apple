@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Split out of ``CardDefTests`` purely to stay under SwiftLint's file/type length
/// limits: covers `CardDef`'s unconstrained (schema-`{}`) fields, `uniqueItems`
/// duplicate-rejection, and nonempty-artwork-identifier validation (issue #2).
@Suite("CardDef unconstrained fields, uniqueItems, and artwork identifiers")
struct CardDefUnconstrainedFieldTests {
    // MARK: - Unconstrained ({}) fields preserve absent/null/value (issue #2)

    private static let unconstrainedFieldNames: [String] = [
        "additionalCost", "fastWindow", "actions", "criteria", "uses", "locationSymbol",
        "locationRevealedSymbol", "purchaseTrauma", "customizations",
    ]

    @Test(
        "Every unconstrained ({}) field accepts an explicit null and decodes to .null",
        arguments: CardDefUnconstrainedFieldTests.unconstrainedFieldNames
    )
    func unconstrainedFieldAcceptsExplicitNull(fieldName: String) throws {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020", "\(fieldName)": null}
        """
        let card = try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        let field: OptionalField<JSONValue> = try #require(
            card.value(forUnconstrainedField: fieldName)
        )
        #expect(field == .null, "\(fieldName) should decode to .null")
    }

    @Test(
        "Every unconstrained ({}) field stays .absent when the key is entirely omitted",
        arguments: CardDefUnconstrainedFieldTests.unconstrainedFieldNames
    )
    func unconstrainedFieldAbsentByDefault(fieldName: String) throws {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020"}
        """
        let card = try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        let field: OptionalField<JSONValue> = try #require(
            card.value(forUnconstrainedField: fieldName)
        )
        #expect(field == .absent, "\(fieldName) should be .absent")
    }

    @Test("additionalCost re-encodes an explicit null as an explicit null, not an omitted key")
    func additionalCostNullRoundTrips() throws {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020", "additionalCost": null}
        """
        let card = try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        #expect(card.additionalCost == .null)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(card)
        let reencoded = try #require(String(data: data, encoding: .utf8))
        #expect(reencoded.contains("\"additionalCost\":null"))
    }

    @Test("A present, non-null value for an unconstrained field round-trips exactly")
    func unconstrainedFieldValueRoundTrips() throws {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020", "criteria": {"nested": [1, 2]}}
        """
        let card = try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        let expectedNested: [JSONValue] = [.number(.integer(1)), .number(.integer(2))]
        #expect(card.criteria == .value(.object(["nested": .array(expectedNested)])))
        let data = try JSONEncoder().encode(card)
        let redecoded = try JSONDecoder().decode(CardDef.self, from: data)
        #expect(redecoded.criteria == card.criteria)
    }

    @Test("A number nested inside an unconstrained field round-trips losslessly via ContractJSON")
    func unconstrainedFieldNumberIsLosslessThroughContractJSON() throws {
        // The schema leaves `criteria` entirely unconstrained, so nothing stops a huge
        // number from appearing inside it; this proves the exact same precision guarantee
        // extends to every embedded `JSONValue`, not only the top-level `ExternalID` case.
        let literal = String(repeating: "9", count: 45)
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020", "criteria": {"huge": \(literal)}}
        """
        let card = try ContractJSON.decode(CardDef.self, from: Data(json.utf8))
        guard
            case let .value(.object(fields)) = card.criteria,
            case let .number(number) = fields["huge"]
        else {
            let description = String(describing: card.criteria)
            Issue.record("Expected criteria.huge to be a .number, got \(description)")
            return
        }
        #expect(number.coefficient == literal)
        let reencoded = try ContractJSON.encode(card)
        let reencodedText = try #require(String(data: reencoded, encoding: .utf8))
        #expect(reencodedText.contains(literal))
    }

    @Test("An absent unconstrained field is omitted entirely on re-encode")
    func unconstrainedFieldAbsentOmittedOnEncode() throws {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020"}
        """
        let card = try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        let data = try JSONEncoder().encode(card)
        let reencoded = try #require(String(data: data, encoding: .utf8))
        for fieldName in CardDefUnconstrainedFieldTests.unconstrainedFieldNames {
            #expect(!reencoded.contains("\"\(fieldName)\""), "\(fieldName) should be omitted")
        }
    }

    // MARK: - uniqueItems: duplicate rejection

    @Test("Duplicate classSymbols are rejected, not silently collapsed")
    func duplicateClassSymbolsRejected() {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020",
         "classSymbols": ["Guardian", "Guardian"]}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        }
    }

    @Test("Duplicate cardTraits are rejected, not silently collapsed")
    func duplicateCardTraitsRejected() {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020",
         "cardTraits": ["Item", "Item"]}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        }
    }

    @Test("Duplicate revealedCardTraits are rejected, not silently collapsed")
    func duplicateRevealedCardTraitsRejected() {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020",
         "revealedCardTraits": ["Item", "Item"]}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        }
    }

    @Test("Non-duplicate classSymbols preserve their original order")
    func classSymbolsPreservesOrder() throws {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": "01020",
         "classSymbols": ["Seeker", "Guardian", "Mystic"]}
        """
        let card = try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        #expect(card.classSymbols?.elements == [.seeker, .guardian, .mystic])
    }

    // MARK: - Nonempty artwork identifiers (minLength: 1)

    @Test("An empty art identifier is rejected")
    func emptyArtRejected() {
        let json = """
        {"cardCode": "c01020", "name": {"title": "X", "subtitle": null},
         "cardType": "AssetType", "art": ""}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CardDef.self, from: Data(json.utf8))
        }
    }

    @Test("An empty investigatorArtwork entry is rejected")
    func emptyInvestigatorArtworkEntryRejected() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(InvestigatorArtwork.self, from: Data(#"[""]"#.utf8))
        }
    }

    @Test("A nonempty investigatorArtwork list round-trips exactly")
    func investigatorArtworkRoundTrips() throws {
        let decoded = try JSONDecoder().decode(
            InvestigatorArtwork.self,
            from: Data(#"["01001", "01002"]"#.utf8)
        )
        let data = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(InvestigatorArtwork.self, from: data)
        #expect(redecoded == decoded)
        #expect(redecoded.map(\.rawValue) == ["01001", "01002"])
    }
}

private extension CardDef {
    /// Test-only accessor bridging a field name (as used by the parameterized
    /// unconstrained-field tests above) to its ``OptionalField`` value, so a single
    /// parameterized test can exercise all 9 unconstrained fields without 9 near-duplicate
    /// test functions.
    func value(forUnconstrainedField fieldName: String) -> OptionalField<JSONValue>? {
        switch fieldName {
        case "additionalCost": additionalCost
        case "fastWindow": fastWindow
        case "actions": actions
        case "criteria": criteria
        case "uses": uses
        case "locationSymbol": locationSymbol
        case "locationRevealedSymbol": locationRevealedSymbol
        case "purchaseTrauma": purchaseTrauma
        case "customizations": customizations
        default: nil
        }
    }
}
