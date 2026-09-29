@testable import ArkhamHorrorShared
import Foundation
import Testing

private actor ScriptedLobbyDeckService: DeckServicing {
    private(set) var validatedDeckLists: [DeckListInput] = []
    private var listQueue: [Result<DeckListResponse, any Error>] = []
    private var validateQueue: [Result<DeckValidationSuccess, any Error>] = []

    func enqueueList(_ result: Result<DeckListResponse, any Error>) {
        listQueue.append(result)
    }

    func enqueueValidate(_ result: Result<DeckValidationSuccess, any Error>) {
        validateQueue.append(result)
    }

    private func consume<T>(_ queue: inout [Result<T, any Error>]) throws -> T {
        guard !queue.isEmpty else { throw TestFailure() }
        return try queue.removeFirst().get()
    }

    func listDecks(on _: ServerProfile, token _: String) async throws -> DeckListResponse {
        try consume(&listQueue)
    }

    func fetchDeckList(
        _: FetchDeckRequest, on _: ServerProfile, token _: String
    ) async throws -> DeckList {
        throw TestFailure()
    }

    func createDeck(_: CreateDeckRequest, on _: ServerProfile, token _: String) async throws -> Deck {
        throw TestFailure()
    }

    func importDeck(from _: String, on _: ServerProfile, token _: String) async throws -> Deck {
        throw TestFailure()
    }

    func deleteDeck(_: DeckID, on _: ServerProfile, token _: String) async throws {
        throw TestFailure()
    }

    func validateDeckList(
        _ deckList: DeckListInput, on _: ServerProfile, token _: String
    ) async throws -> DeckValidationSuccess {
        validatedDeckLists.append(deckList)
        return try consume(&validateQueue)
    }
}

private struct LobbyDeckFixture: Decodable {
    let deck: Deck
    let validationErrors: DeckValidationErrors
    let operationError: DeckOperationError
}

@MainActor
@Suite("LobbyDeckSelectionViewModel")
struct LobbyDeckSelectionViewModelTests {
    private func loadFixture() throws -> LobbyDeckFixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "decks", withExtension: "json", subdirectory: "Fixtures/Contract"
            )
        )
        return try ContractJSON.decode(LobbyDeckFixture.self, from: Data(contentsOf: url))
    }

    private func makeModel(service: ScriptedLobbyDeckService) -> LobbyDeckSelectionViewModel {
        LobbyDeckSelectionViewModel(profile: .hosted, deckService: service) { "token" }
    }

    private func deck(_ source: Deck, investigatorCode: String, name: String) throws -> Deck {
        let code = try CardCode(investigatorCode)
        let list = DeckList(
            slots: source.list.slots,
            sideSlots: source.list.sideSlots,
            investigatorCode: code,
            investigatorName: name,
            meta: source.list.meta,
            tabooId: source.list.tabooId,
            url: source.list.url,
            id: source.list.id,
            name: name
        )
        return Deck(
            id: DeckID(UUID()),
            userId: source.userId,
            url: source.url,
            name: name,
            investigatorName: name,
            list: list
        )
    }

    @Test("load filters by investigator and normalizes c-prefixed codes")
    func loadFiltersByInvestigator() async throws {
        let fixture = try loadFixture()
        let roland = fixture.deck
        let daisy = try deck(fixture.deck, investigatorCode: "c01002", name: "Daisy Walker")
        let service = ScriptedLobbyDeckService()
        await service.enqueueList(.success([daisy, roland]))
        await service.enqueueValidate(.success(DeckValidationSuccess()))
        let model = makeModel(service: service)

        await model.load(allowedInvestigatorIDs: ["01001"])

        #expect(model.decks == [roland])
        #expect(model.validationState(for: roland) == .valid)
    }

    @Test("validation records invalid and failed states per deck")
    func validationStates() async throws {
        let fixture = try loadFixture()
        let roland = fixture.deck
        let daisy = try deck(fixture.deck, investigatorCode: "c01002", name: "Daisy Walker")
        let service = ScriptedLobbyDeckService()
        await service.enqueueList(.success([roland, daisy]))
        await service.enqueueValidate(.failure(DeckServiceError.validationFailed(fixture.validationErrors)))
        await service.enqueueValidate(.failure(DeckServiceError.operationFailed(fixture.operationError)))
        let model = makeModel(service: service)

        await model.load(allowedInvestigatorIDs: ["01001", "01002"])

        #expect(model.validationState(for: roland) == .invalid("Unsupported card c99999"))
        #expect(model.validationState(for: daisy) == .failed("Could not sync deck"))
    }

    @Test("cancelled validation can be retried by calling load again")
    func cancelledValidationRetries() async throws {
        let fixture = try loadFixture()
        let service = ScriptedLobbyDeckService()
        await service.enqueueList(.success([fixture.deck]))
        await service.enqueueValidate(.failure(CancellationError()))
        let model = makeModel(service: service)

        await model.load(allowedInvestigatorIDs: ["01001"])
        #expect(model.validationState(for: fixture.deck) == .pending)

        await service.enqueueList(.success([fixture.deck]))
        await service.enqueueValidate(.success(DeckValidationSuccess()))
        await model.load(allowedInvestigatorIDs: ["01001"])

        #expect(model.validationState(for: fixture.deck) == .valid)
    }

    @Test("validation sends playList instead of list when a 0.1.46 deck provides one")
    func validationUsesPlayableList() async throws {
        let fixture = try loadFixture()
        let playList = DeckList(
            slots: try CardQuantityMap([CardCode("c01016"): 1]),
            sideSlots: fixture.deck.list.sideSlots,
            investigatorCode: fixture.deck.list.investigatorCode,
            investigatorName: fixture.deck.list.investigatorName,
            meta: fixture.deck.list.meta,
            tabooId: fixture.deck.list.tabooId,
            url: fixture.deck.list.url,
            id: fixture.deck.list.id,
            name: fixture.deck.list.name
        )
        let deck = Deck(
            id: fixture.deck.id,
            userId: fixture.deck.userId,
            url: fixture.deck.url,
            name: fixture.deck.name,
            investigatorName: fixture.deck.investigatorName,
            list: fixture.deck.list,
            playList: playList
        )
        let service = ScriptedLobbyDeckService()
        await service.enqueueList(.success([deck]))
        await service.enqueueValidate(.success(DeckValidationSuccess()))
        let model = makeModel(service: service)

        await model.load(allowedInvestigatorIDs: ["01001"])

        #expect(await service.validatedDeckLists == [DeckListInput(playList)])
    }

    @Test("claimedInvestigatorID matches normalized deck investigator codes")
    func claimedInvestigatorID() throws {
        let fixture = try loadFixture()
        let model = makeModel(service: ScriptedLobbyDeckService())
        let investigators = [
            InvestigatorSummary(id: "01001", classSymbol: .init("Guardian")),
            InvestigatorSummary(id: "01002", classSymbol: .init("Seeker")),
        ]

        #expect(
            model.claimedInvestigatorID(for: fixture.deck, in: investigators) == "01001"
        )
    }
}
