@testable import ArkhamHorrorShared
import Foundation
import Testing

private actor ScriptedDeckHTTPTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var responses: [(Data, URLResponse)]

    init(responses: [(Data, URLResponse)]) {
        self.responses = responses
    }

    nonisolated func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await recordAndReturn(request)
    }

    private func recordAndReturn(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw TestFailure() }
        return responses.removeFirst()
    }
}

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

    @Test(
        "Import URL recognition rewrites only supported HTTPS ArkhamDB and arkham.build links",
        arguments: [
            (
                "https://arkhamdb.com/decklist/view/4242",
                "https://arkhamdb.com/api/public/decklist/4242"
            ),
            (
                "https://arkhamdb.com/deck/4242",
                "https://arkhamdb.com/api/public/deck/4242"
            ),
            (
                "https://en.arkhamdb.com/decklist/4242",
                "https://arkhamdb.com/api/public/decklist/4242"
            ),
            (
                "https://arkhamdb.com/decklist/view/2381/roland-1.0",
                "https://arkhamdb.com/api/public/decklist/2381"
            ),
            (
                "https://arkham.build/decklist/view/abc123",
                "https://arkham.build/decklist/abc123"
            ),
            (
                "HTTPS://User@Arkham.Build:8443/decklist/ABC_123?x=1#fragment",
                "https://arkham.build/decklist/ABC_123"
            ),
        ]
    )
    func importURLRecognition(rawURL: String, fetchURL: String) throws {
        #expect(try DeckImportURL.parse(rawURL).fetchURL == fetchURL)
    }

    @Test(
        "Import URL recognition rejects unsupported and SSRF-shaped inputs",
        arguments: [
            "http://arkhamdb.com/decklist/view/4242",
            "https://example.com/decklist/view/4242",
            "https://127.0.0.1/decklist/view/4242",
            "https://localhost/decklist/view/4242",
            "https://169.254.169.254/latest/meta-data",
            "https://arkhamdb.com.evil.test/decklist/view/4242",
            "https://arkhamdb.com/decklist/view/not-a-number",
            "https://arkhamdb.com/decklist/view/٣٣",
            "https://аrkham.build/decklist/abc123",
            "https://arkham.build/decklist/éabc",
            "https://arkham.build/decklist/../secret",
            "https://arkham.build/share/abc123",
            "https://arkham.build/deck/view/abc123",
        ]
    )
    func importURLRecognitionRejects(rawURL: String) {
        #expect(throws: DeckImportURL.ParseError.self) {
            try DeckImportURL.parse(rawURL)
        }
    }

    @Test("importDeck fetches the normalized URL then creates a deck with derived fields")
    func importDeckFetchThenCreate() async throws {
        let fixture = try loadFixture()
        let fetchEndpoint = profile.endpointURL(path: "/arkham/decks/fetch")
        let createEndpoint = profile.endpointURL(path: "/arkham/decks")
        let fetched = DeckList(
            slots: fixture.normalizedDeckList.slots,
            sideSlots: fixture.normalizedDeckList.sideSlots,
            investigatorCode: fixture.normalizedDeckList.investigatorCode,
            investigatorName: fixture.normalizedDeckList.investigatorName,
            meta: fixture.normalizedDeckList.meta,
            tabooId: fixture.normalizedDeckList.tabooId,
            url: nil,
            id: "4242.0",
            name: "Contract deck"
        )
        let transport = try ScriptedDeckHTTPTransport(responses: [
            (ContractJSON.encode(fetched), httpResponse(200, url: fetchEndpoint)),
            (ContractJSON.encode(fixture.deck), httpResponse(200, url: createEndpoint)),
        ])
        let service = DeckService(transport: transport)

        _ = try await service.importDeck(
            from: "https://arkhamdb.com/decklist/view/4242",
            on: profile,
            token: token
        )

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST"])
        let fetchBody = try #require(requests[0].httpBody)
        #expect(
            try ContractJSON.decode(FetchDeckRequest.self, from: fetchBody)
                == FetchDeckRequest(url: "https://arkhamdb.com/api/public/decklist/4242")
        )
        let createBody = try #require(requests[1].httpBody)
        let createRequest = try ContractJSON.decode(CreateDeckRequest.self, from: createBody)
        #expect(createRequest.deckId == "4242.0")
        #expect(createRequest.deckName == "Contract deck")
        #expect(createRequest.deckUrl == nil)
        #expect(createRequest.deckList == DeckListInput(fetched))
    }

    @Test("fetchDeckList maps 5xx remote fetch failures to an ArkhamDB reachability message")
    func fetchDeckListRemoteFailure() async throws {
        let fixture = try loadFixture()
        let url = profile.endpointURL(path: "/arkham/decks/fetch")
        let transport = GameLifecycleRecordingTransport(
            data: Data(), response: httpResponse(500, url: url)
        )
        let service = DeckService(transport: transport)
        await #expect(throws: DeckServiceError.remoteDeckSourceUnavailable) {
            _ = try await service.fetchDeckList(fixture.fetchDeck, on: profile, token: token)
        }
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
