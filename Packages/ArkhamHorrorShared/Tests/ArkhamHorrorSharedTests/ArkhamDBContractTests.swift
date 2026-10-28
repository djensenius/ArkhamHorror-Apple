@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ArkhamDB contract")
struct ArkhamDBContractTests {
    private struct Fixture: Decodable {
        let linkStart: ArkhamDBLinkStartResponse
        let linkedStatus: ArkhamDBLinkStatus
        let unlinkedStatus: ArkhamDBLinkStatus
        let decks: [ArkhamDBRemoteDeckSummary]
        let completionRequest: ArkhamDBLinkCompletionRequest
        let importRequest: ArkhamDBImportRequest
        let importedDeck: Deck
        let syncedDeck: Deck
        let error: ArkhamDBError
        let tokenExpiredError: ArkhamDBError
    }

    private func fixtureData(_ name: String = "arkhamdb") throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/Contract"
        ))
        return try Data(contentsOf: url)
    }

    private func fixture() throws -> Fixture {
        try ContractJSON.decode(Fixture.self, from: fixtureData())
    }

    private func object(_ name: String) throws -> [String: JSONValue] {
        let root = try ContractJSON.decode([String: JSONValue].self, from: fixtureData())
        let value: JSONValue? = if name == "deckSummary", case let .array(decks) = root["decks"] {
            decks.first
        } else {
            root[name]
        }
        guard case let .object(fields) = try #require(value) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return fields
    }

    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: JSONValue]) throws -> T {
        try ContractJSON.decode(type, from: ContractJSON.encode(JSONValue.object(object)))
    }

    @Test("The governed fixture decodes link start and both linked and unlinked status")
    func linkResponses() throws {
        let fixture = try fixture()
        #expect(fixture.linkStart
            .authorizeUrl ==
            "https://arkhamdb.example/oauth/v2/auth?response_type=code&client_id=client&redirect_uri=https%3A%2F%2Fserver.example%2Fapi%2Fv1%2Farkham%2Farkhamdb%2Fcallback&state=nonce") // swiftlint:disable:this line_length
        #expect(fixture.linkStart.expiresAt == "2026-10-19T12:10:00Z")
        let linked = fixture.linkedStatus
        #expect(linked.linked)
        #expect(linked.remoteAccountId == "42")
        #expect(linked.remoteAccountName == "Investigator")
        #expect(linked.tokenExpiry == "2026-10-19T13:00:00Z")
        #expect(linked.linkedAt == "2026-10-19T12:00:00Z")
        #expect(linked.writeBackEnabledDeckCount == 0)
        let unlinked = fixture.unlinkedStatus
        #expect(!unlinked.linked)
        #expect(unlinked.remoteAccountId == nil)
        #expect(unlinked.remoteAccountName == nil)
        #expect(unlinked.tokenExpiry == nil)
        #expect(unlinked.linkedAt == nil)
        #expect(unlinked.writeBackEnabledDeckCount == 0)
    }

    @Test("The governed remote deck summary preserves remote metadata and the local mapping")
    func remoteDeckSummary() throws {
        let fixture = try fixture()
        #expect(fixture.decks.count == 1)
        let deck = try #require(fixture.decks.first)
        #expect(deck.id == "123")
        #expect(deck.name == "Private deck")
        #expect(deck.url == nil)
        #expect(deck.investigatorName == "Roland Banks")
        #expect(deck.lastUpdatedAt == "2026-10-19T11:00:00Z")
        #expect(deck.version == "1.0")
        #expect(deck.linkedLocalDeckId == nil)
        var fields = try object("deckSummary")
        fields["linkedLocalDeckId"] = .string("00000000-0000-0000-0000-000000000017")
        #expect(try decode(ArkhamDBRemoteDeckSummary.self, fields).linkedLocalDeckId == fixture
            .importedDeck.id)
        fields["linkedLocalDeckId"] = .string("not-a-uuid")
        #expect(throws: (any Error).self) { try decode(ArkhamDBRemoteDeckSummary.self, fields) }
    }

    @Test("Import and sync return the existing saved Deck shape without losing the playable list")
    func savedDeckResponses() throws {
        let fixture = try fixture()
        #expect(fixture.importRequest.deckId == "123")
        #expect(fixture.syncedDeck == fixture.importedDeck)
        let deck = fixture.importedDeck
        #expect(deck.id.description == "00000000-0000-0000-0000-000000000017")
        #expect(deck.userId == 1)
        #expect(deck.name == "Private deck")
        #expect(deck.url == "https://arkhamdb.example/api/public/deck/123")
        #expect(deck.investigatorName == "Roland Banks")
        #expect(deck.list.id == "123")
        #expect(deck.list.investigatorCode.rawValue == "c01001")
        #expect(deck.playList == deck.list)
        #expect(deck.lastUsedAt == nil)
        #expect(deck.overlay == nil)
    }

    @Test("The completion request is a nonempty single-use secret and success is exactly []")
    func completion() throws {
        #expect(try fixture().completionRequest.completion.rawValue == "completion-secret")
        let response = try ContractJSON.decode(
            ArkhamDBLinkCompletionResponse.self,
            from: Data("[]".utf8)
        )
        #expect(try ContractJSON.encode(response) == Data("[]".utf8))
        for json in ["null", "{}", "[null]", "[true]", "[[]]"] {
            #expect(throws: (any Error).self) {
                try ContractJSON.decode(ArkhamDBLinkCompletionResponse.self, from: Data(json.utf8))
            }
        }
        #expect(throws: (any Error).self) {
            try decode(ArkhamDBLinkCompletionRequest.self, ["completion": .string("")])
        }
    }

    @Test("HTTP 409 notLinked and tokenExpired are typed remote-account errors, not session expiry")
    func relinkingErrors() throws {
        let fixture = try fixture()
        #expect(fixture.error.code == .notLinked)
        #expect(fixture.error.error == "ArkhamDB account is not linked")
        #expect(fixture.error.requiresRelinking)
        #expect(fixture.tokenExpiredError.code == .tokenExpired)
        #expect(fixture.tokenExpiredError.error == "ArkhamDB rejected the token; relink required")
        #expect(fixture.tokenExpiredError.requiresRelinking)
    }

    @Test("Every governed error code decodes as its exact typed case")
    func errorCodes() throws {
        let expected: [(String, ArkhamDBErrorCode)] = [
            ("disabled", .disabled), ("oauthCallbackInvalidState", .oauthCallbackInvalidState),
            ("notLinked", .notLinked), ("tokenExpired", .tokenExpired), ("notFound", .notFound),
            ("storageFailure", .storageFailure), ("remoteUnavailable", .remoteUnavailable),
            ("oauthCompletionInvalid", .oauthCompletionInvalid),
        ]
        for (raw, code) in expected {
            let error = try decode(
                ArkhamDBError.self,
                ["code": .string(raw), "error": .string("message")]
            )
            #expect(error.code == code)
            #expect(error.requiresRelinking == (code == .notLinked || code == .tokenExpired))
        }
        let unknown = try decode(
            ArkhamDBError.self,
            ["code": .string("sessionExpired"), "error": .string("message")]
        )
        #expect(unknown.code == .unknown("sessionExpired"))
        #expect(!unknown.requiresRelinking)
    }

    @Test("Required keys, including nullable keys, reject missing and wrongly typed values")
    func strictRequiredKeys() throws {
        try assertRequiredKeys(ArkhamDBLinkStartResponse.self, name: "linkStart")
        try assertRequiredKeys(ArkhamDBLinkStatus.self, name: "linkedStatus")
        try assertRequiredKeys(ArkhamDBLinkStatus.self, name: "unlinkedStatus")
        try assertRequiredKeys(ArkhamDBRemoteDeckSummary.self, name: "deckSummary")
        try assertRequiredKeys(ArkhamDBLinkCompletionRequest.self, name: "completionRequest")
        try assertRequiredKeys(ArkhamDBImportRequest.self, name: "importRequest")
        try assertRequiredKeys(ArkhamDBError.self, name: "error")
    }

    private func assertRequiredKeys(_ type: (some Decodable).Type, name: String) throws {
        let fields = try object(name)
        for key in fields.keys {
            var missing = fields
            missing.removeValue(forKey: key)
            #expect(throws: (any Error).self, "Missing \(name).\(key)") { try decode(type, missing)
            }
            var invalid = fields
            invalid[key] = .array([])
            #expect(throws: (any Error).self, "Wrong type \(name).\(key)") { try decode(
                type,
                invalid
            ) }
        }
    }

    @Test(
        "Nullability, non-negative integer counts and decimal remote deck IDs are enforced"
    )
    func constraints() throws {
        for key in ["linked", "writeBackEnabledDeckCount"] {
            var fields = try object("linkedStatus")
            fields[key] = .null
            #expect(throws: (any Error).self) { try decode(ArkhamDBLinkStatus.self, fields) }
        }
        var status = try object("linkedStatus")
        for invalid: JSONValue in try [
            .number(.integer(-1)),
            .number(JSONNumber(exactDecimalLiteral: "0.5")),
            .bool(true),
            .string("0"),
        ] {
            status["writeBackEnabledDeckCount"] = invalid
            #expect(throws: (any Error).self) { try decode(ArkhamDBLinkStatus.self, status) }
        }
        status["writeBackEnabledDeckCount"] = .number(.integer(3))
        #expect(try decode(ArkhamDBLinkStatus.self, status).writeBackEnabledDeckCount == 3)
        for invalid in ["", "-1", "1.0", "١٢٣", "12a", " 123"] {
            #expect(throws: (any Error).self) {
                try decode(ArkhamDBImportRequest.self, ["deckId": .string(invalid)])
            }
        }
        var deck = try object("deckSummary")
        for key in ["url", "investigatorName", "lastUpdatedAt", "version", "linkedLocalDeckId"] {
            deck[key] = .null
        }
        let nullable = try decode(ArkhamDBRemoteDeckSummary.self, deck)
        #expect(nullable.url == nil && nullable.investigatorName == nil && nullable
            .lastUpdatedAt == nil)
        #expect(nullable.version == nil && nullable.linkedLocalDeckId == nil)
    }

    @Test(
        "Additive fields are ignored, and encoding preserves required nulls and contract spelling"
    )
    func additiveFieldsAndRoundTrip() throws {
        try assertRoundTrip(ArkhamDBLinkStartResponse.self, name: "linkStart")
        try assertRoundTrip(ArkhamDBLinkStatus.self, name: "linkedStatus")
        try assertRoundTrip(ArkhamDBLinkStatus.self, name: "unlinkedStatus")
        try assertRoundTrip(ArkhamDBRemoteDeckSummary.self, name: "deckSummary")
        try assertRoundTrip(ArkhamDBLinkCompletionRequest.self, name: "completionRequest")
        try assertRoundTrip(ArkhamDBImportRequest.self, name: "importRequest")
        try assertRoundTrip(ArkhamDBError.self, name: "error")
    }

    private func assertRoundTrip(_ type: (some Codable & Equatable).Type, name: String) throws {
        let fields = try object(name)
        let original = try decode(type, fields)
        var additive = fields
        additive["futureField"] = .object(["nested": .array([.bool(true)])])
        #expect(try decode(type, additive) == original)
        let encoded = try ContractJSON.encode(original)
        #expect(try ContractJSON.decode(JSONValue.self, from: encoded) == .object(fields))
        #expect(try ContractJSON.decode(type, from: encoded) == original)
    }
}
