@testable import ArkhamHorrorShared
import Foundation
import Testing

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

@Suite("DeckService")
struct DeckServiceTests {
    private let profile = ServerProfile.hosted
    private let token = "the-session-token"

    private func httpResponse(_ status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

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

    @Test("listDecks issues GET /arkham/decks with Authorization and decodes deck arrays")
    func listDecksRequestShape() async throws {
        let fixture = try loadFixture()
        let url = profile.endpointURL(path: "/arkham/decks")
        let transport = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode([fixture.deck]),
            response: httpResponse(200, url: url)
        )
        let service = DeckService(transport: transport)

        let decks = try await service.listDecks(on: profile, token: token)

        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "GET")
        #expect(request?.url?.absoluteString == "https://arkhamhorror.app/api/v1/arkham/decks")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Token \(token)")
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request?.httpBody == nil)
        #expect(decks == [fixture.deck])
    }

    @Test("fetchDeckList posts FetchDeckRequest and decodes normalized deck lists")
    func fetchDeckListRequestShape() async throws {
        let fixture = try loadFixture()
        let url = profile.endpointURL(path: "/arkham/decks/fetch")
        let transport = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(fixture.normalizedDeckList),
            response: httpResponse(200, url: url)
        )
        let service = DeckService(transport: transport)

        let deckList = try await service.fetchDeckList(fixture.fetchDeck, on: profile, token: token)

        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "POST")
        #expect(request?.url?.absoluteString.hasSuffix("/arkham/decks/fetch") == true)
        let body = try #require(await transport.capturedBody)
        #expect(try ContractJSON.decode(FetchDeckRequest.self, from: body) == fixture.fetchDeck)
        #expect(deckList == fixture.normalizedDeckList)
    }

    @Test("createDeck posts CreateDeckRequest and maps validation errors")
    func createDeckRequestAndValidationFailure() async throws {
        let fixture = try loadFixture()
        let url = profile.endpointURL(path: "/arkham/decks")
        let successTransport = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(fixture.deck),
            response: httpResponse(200, url: url)
        )
        let service = DeckService(transport: successTransport)
        let deck = try await service.createDeck(fixture.createDeck, on: profile, token: token)
        let body = try #require(await successTransport.capturedBody)
        #expect(try ContractJSON.decode(CreateDeckRequest.self, from: body) == fixture.createDeck)
        #expect(deck == fixture.deck)

        let failureTransport = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(fixture.validationErrors),
            response: httpResponse(400, url: url)
        )
        let failingService = DeckService(transport: failureTransport)
        await #expect(throws: DeckServiceError.validationFailed(fixture.validationErrors)) {
            _ = try await failingService.createDeck(fixture.createDeck, on: profile, token: token)
        }
    }

    @Test("validateDeckList decodes empty-array success and 400 validation errors")
    func validateDeckListStatusMapping() async throws {
        let fixture = try loadFixture()
        let url = profile.endpointURL(path: "/arkham/decks/validate")
        let successTransport = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(fixture.validationSuccess),
            response: httpResponse(200, url: url)
        )
        let service = DeckService(transport: successTransport)
        #expect(
            try await service.validateDeckList(
                fixture.validateDeckList, on: profile, token: token
            ) == fixture.validationSuccess
        )

        let failureTransport = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(fixture.validationErrors),
            response: httpResponse(400, url: url)
        )
        let failingService = DeckService(transport: failureTransport)
        await #expect(throws: DeckServiceError.validationFailed(fixture.validationErrors)) {
            _ = try await failingService.validateDeckList(
                fixture.validateDeckList, on: profile, token: token
            )
        }
    }

    @Test("deleteDeck issues DELETE /arkham/decks/:id and accepts empty success bodies")
    func deleteDeckRequestShape() async throws {
        let fixture = try loadFixture()
        let url = profile.endpointURL(
            path: "/arkham/decks/\(fixture.deck.id.rawValue.uuidString)"
        )
        let transport = GameLifecycleRecordingTransport(
            data: Data(), response: httpResponse(200, url: url)
        )
        let service = DeckService(transport: transport)
        try await service.deleteDeck(fixture.deck.id, on: profile, token: token)
        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "DELETE")
        let expectedSuffix = "/arkham/decks/00000000-0000-0000-0000-000000000017"
        #expect(request?.url?.absoluteString.hasSuffix(expectedSuffix) == true)
        #expect(request?.httpBody == nil)
    }

    @Test("fetchDeckList maps 400 operation errors")
    func fetchDeckListOperationError() async throws {
        let fixture = try loadFixture()
        let url = profile.endpointURL(path: "/arkham/decks/fetch")
        let transport = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(fixture.operationError),
            response: httpResponse(400, url: url)
        )
        let service = DeckService(transport: transport)
        await #expect(throws: DeckServiceError.operationFailed(fixture.operationError)) {
            _ = try await service.fetchDeckList(fixture.fetchDeck, on: profile, token: token)
        }
    }
}
