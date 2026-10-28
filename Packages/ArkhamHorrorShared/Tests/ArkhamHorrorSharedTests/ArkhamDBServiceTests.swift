@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ArkhamDBService")
struct ArkhamDBServiceTests {
    @Test("Remote deck decoding isolates and reports a malformed row between valid entries")
    func listIsolation() async throws {
        let values = try ContractJSON.decode([JSONValue].self, from: arkhamDBFixtureData("decks"))
        let row = try #require(values.first)
        let transport = try ArkhamDBScriptedTransport([
            (200, ContractJSON.encode([row, .object(["id": .string("bad")]), .null, row])),
        ])
        let list = try await ArkhamDBService(transport: transport).listDecks(
            on: .hosted,
            token: "token"
        )
        #expect(list.decks.count == 2)
        #expect(list.decks.map(\.name) == ["Private deck", "Private deck"])
        #expect(list.skippedCount == 2)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/api/v1/arkham/arkhamdb/decks")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(!request.httpShouldHandleCookies)
    }

    @Test("An invalid deck-list envelope still reports a payload failure")
    func malformedListEnvelope() async {
        let transport = ArkhamDBScriptedTransport([(200, Data("{}".utf8))])
        await #expect(throws: DeckServiceError.malformedPayload) {
            try await ArkhamDBService(transport: transport).listDecks(on: .hosted, token: "token")
        }
    }

    @Test("Known and unreadable 409s remain ArkhamDB errors, never session expiry")
    func conflictsAreNotSessionExpiry() async throws {
        for (data, expected) in try [
            (
                arkhamDBFixtureData("error"),
                DeckServiceError.arkhamDB(arkhamDBFixture(ArkhamDBError.self, "error"))
            ),
            (
                arkhamDBFixtureData("tokenExpiredError"),
                .arkhamDB(arkhamDBFixture(ArkhamDBError.self, "tokenExpiredError"))
            ),
            (Data("not JSON".utf8), .arkhamDB(nil)),
        ] {
            let service = ArkhamDBService(transport: ArkhamDBScriptedTransport([(409, data)]))
            await #expect(throws: expected) {
                try await service.listDecks(on: .hosted, token: "still-signed-in")
            }
            #expect(expected != .sessionExpired)
        }
    }

    @Test("Only HTTP 401 expires the app session; unconfigured linking stays a feature error")
    func unauthorizedAndDisabled() async throws {
        let unauthorized = ArkhamDBService(transport: ArkhamDBScriptedTransport([(401, Data())]))
        await #expect(throws: DeckServiceError.sessionExpired) {
            try await unauthorized.status(on: .hosted, token: "expired")
        }
        let disabled = ArkhamDBError(code: .disabled, error: "server content must not be shown")
        let service = try ArkhamDBService(transport: ArkhamDBScriptedTransport([(
            501,
            ContractJSON.encode(disabled)
        )]))
        await #expect(throws: DeckServiceError.arkhamDB(disabled)) {
            try await service.status(on: .hosted, token: "valid")
        }
        #expect(!DeckServiceError.arkhamDB(disabled).message.contains(disabled.error))
    }

    @Test("Import uses the linked endpoint and returns a saved deck; unlink uses DELETE")
    func importAndUnlink() async throws {
        let deck = try arkhamDBFixture(Deck.self, "importedDeck")
        let transport = try ArkhamDBScriptedTransport([
            (200, arkhamDBFixtureData("importedDeck")), (200, Data("[]".utf8)),
        ])
        let service = ArkhamDBService(transport: transport)
        let result = try await service.importDeck(
            ArkhamDBImportRequest(deckId: "123"),
            on: .hosted,
            token: "token"
        )
        #expect(result == deck)
        try await service.unlink(on: .hosted, token: "token")
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(requests.map { $0.url?.path } == [
            "/api/v1/arkham/arkhamdb/decks/import", "/api/v1/arkham/arkhamdb/link",
        ])
        let body = try #require(requests.first?.httpBody)
        #expect(try ContractJSON
            .decode(JSONValue.self, from: body) == .object(["deckId": .string("123")]))
        #expect(requests.first?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("Linked sync and import preserve public deck operation errors", arguments: [400, 500, 501, 502])
    func publicDeckOperationErrors(status: Int) async throws {
        let data = status == 400 ? Data(#"{"errorMsg":"Could not sync deck"}"#.utf8) : Data()
        let expected: DeckServiceError = status == 400
            ? .operationFailed(DeckOperationError(errorMsg: "Could not sync deck"))
            : .remoteDeckSourceUnavailable
        let deck = try arkhamDBFixture(Deck.self, "importedDeck")
        let transport = ArkhamDBScriptedTransport([(status, data), (status, data)])
        let service = ArkhamDBService(transport: transport)
        let sync = ArkhamDBSyncDeckService(base: DeckService(), arkhamDB: service)
        await #expect(throws: expected) {
            try await sync.syncDeck(deck.id, on: .hosted, token: "token", timeout: 7)
        }
        await #expect(throws: expected) {
            try await service.importDeck(ArkhamDBImportRequest(deckId: "123"), on: .hosted, token: "token")
        }
        let legacy = DeckService(transport: ArkhamDBScriptedTransport([(status, data), (status, data)]))
        await #expect(throws: expected) {
            try await legacy.syncDeck(deck.id, on: .hosted, token: "token", timeout: 7)
        }
        await #expect(throws: expected) {
            try await legacy.importDeck(from: "https://arkhamdb.com/deck/view/123", on: .hosted, token: "token")
        }
    }

    @Test("Capability-enabled saved deck sync uses the server-owned mapping route")
    func linkedSyncRoute() async throws {
        let deck = try arkhamDBFixture(Deck.self, "importedDeck")
        let transport = try ArkhamDBScriptedTransport([(200, arkhamDBFixtureData("syncedDeck"))])
        let service = ArkhamDBSyncDeckService(
            base: DeckService(),
            arkhamDB: ArkhamDBService(transport: transport)
        )
        #expect(try await service
            .syncDeck(deck.id, on: .hosted, token: "token", timeout: 7) == deck)
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?
            .path == "/api/v1/arkham/arkhamdb/decks/00000000-0000-0000-0000-000000000017/sync")
        #expect(request.timeoutInterval == 7)
    }
}
