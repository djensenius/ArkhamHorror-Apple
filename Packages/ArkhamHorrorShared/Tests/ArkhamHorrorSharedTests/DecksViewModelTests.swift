@testable import ArkhamHorrorShared
import Foundation
import Testing

private actor ScriptedDeckService: DeckServicing {
    private(set) var callOrder: [String] = []
    private(set) var lastImportedURL: String?
    private(set) var lastDeletedID: DeckID?

    private var listQueue: [Result<DeckListResponse, any Error>] = []
    private var importQueue: [Result<Deck, any Error>] = []
    private var deleteQueue: [Result<Void, any Error>] = []
    private var validateQueue: [Result<DeckValidationSuccess, any Error>] = []

    func enqueueList(_ result: Result<DeckListResponse, any Error>) {
        listQueue.append(result)
    }

    func enqueueImport(_ result: Result<Deck, any Error>) {
        importQueue.append(result)
    }

    func enqueueDelete(_ result: Result<Void, any Error>) {
        deleteQueue.append(result)
    }

    func enqueueValidate(_ result: Result<DeckValidationSuccess, any Error>) {
        validateQueue.append(result)
    }

    private func consume<T>(_ queue: inout [Result<T, any Error>]) throws -> T {
        guard !queue.isEmpty else { throw TestFailure() }
        return try queue.removeFirst().get()
    }

    func listDecks(on _: ServerProfile, token _: String) async throws -> DeckListResponse {
        callOrder.append("listDecks")
        return try consume(&listQueue)
    }

    func fetchDeckList(
        _: FetchDeckRequest, on _: ServerProfile, token _: String
    ) async throws -> DeckList {
        throw TestFailure()
    }

    func createDeck(
        _: CreateDeckRequest, on _: ServerProfile, token _: String
    ) async throws -> Deck {
        throw TestFailure()
    }

    func importDeck(from url: String, on _: ServerProfile, token _: String) async throws -> Deck {
        callOrder.append("importDeck")
        lastImportedURL = url
        return try consume(&importQueue)
    }

    func deleteDeck(_ id: DeckID, on _: ServerProfile, token _: String) async throws {
        callOrder.append("deleteDeck")
        lastDeletedID = id
        try consume(&deleteQueue)
    }

    func validateDeckList(
        _: DeckListInput, on _: ServerProfile, token _: String
    ) async throws -> DeckValidationSuccess {
        callOrder.append("validateDeckList")
        return try consume(&validateQueue)
    }
}

private struct DecksViewModelFixture: Decodable {
    let deck: Deck
    let operationError: DeckOperationError
    let validationErrors: DeckValidationErrors
}

@MainActor
@Suite("DecksViewModel")
struct DecksViewModelTests {
    private func loadFixture() throws -> DecksViewModelFixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "decks",
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try ContractJSON.decode(DecksViewModelFixture.self, from: Data(contentsOf: url))
    }

    private func makeModel(service: ScriptedDeckService) -> DecksViewModel {
        DecksViewModel(profile: .hosted, deckService: service) { "token" }
    }

    @Test("load moves through loaded empty and failed states")
    func loadStates() async {
        let service = ScriptedDeckService()
        await service.enqueueList(.success([]))
        let model = makeModel(service: service)

        await model.load()
        #expect(model.loadState == .loaded([]))

        await service.enqueueList(.failure(DeckServiceError.unexpectedStatus(500)))
        await model.load()
        #expect(model.loadState == .failed(DeckServiceError.unexpectedStatus(500).message))
    }

    @Test("blank import URL fails before network and successful import appends the deck")
    func importStates() async throws {
        let fixture = try loadFixture()
        let service = ScriptedDeckService()
        let model = makeModel(service: service)

        await model.importDeck()
        #expect(
            model.importState == .failed(DeckImportURL.ParseError.invalid.message)
        )
        #expect(await service.callOrder.isEmpty)

        model.importURL = " https://arkhamdb.com/decklist/view/4242 "
        await service.enqueueImport(.success(fixture.deck))
        await model.importDeck()

        #expect(model.importState == .idle)
        #expect(model.decks == [fixture.deck])
        #expect(await service.lastImportedURL == "https://arkhamdb.com/decklist/view/4242")
    }

    @Test("import surfaces fetch operation and validation messages clearly")
    func importErrorMessages() async throws {
        let fixture = try loadFixture()
        let service = ScriptedDeckService()
        let model = makeModel(service: service)

        model.importURL = "https://arkhamdb.com/decklist/view/4242"
        await service.enqueueImport(
            .failure(DeckServiceError.operationFailed(fixture.operationError))
        )
        await model.importDeck()
        #expect(model.importState == .failed("Could not sync deck"))

        await service.enqueueImport(
            .failure(DeckServiceError.validationFailed(fixture.validationErrors))
        )
        await model.importDeck()
        #expect(model.importState == .failed("Unsupported card c99999"))
    }

    @Test("delete asks for confirmation then removes the deck through the view-called API")
    func deleteStates() async throws {
        let fixture = try loadFixture()
        let service = ScriptedDeckService()
        let model = makeModel(service: service)
        await service.enqueueList(.success([fixture.deck]))
        await model.load()

        model.requestDelete(fixture.deck)
        #expect(model.pendingDeletion == fixture.deck)
        await service.enqueueDelete(.success(()))
        await model.delete(fixture.deck)

        #expect(model.pendingDeletion == nil)
        #expect(model.decks.isEmpty)
        #expect(await service.lastDeletedID == fixture.deck.id)
    }

    @Test("delete failure leaves the loaded deck list visible and shows an inline error")
    func deleteFailureKeepsLoadedList() async throws {
        let fixture = try loadFixture()
        let service = ScriptedDeckService()
        let model = makeModel(service: service)
        await service.enqueueList(.success([fixture.deck]))
        await model.load()

        await service.enqueueDelete(.failure(DeckServiceError.unexpectedStatus(500)))
        await model.delete(fixture.deck)

        #expect(model.decks == [fixture.deck])
        #expect(model.loadState == .loaded([fixture.deck]))
        #expect(model.deletionFailure == DeckServiceError.unexpectedStatus(500).message)
    }
}
