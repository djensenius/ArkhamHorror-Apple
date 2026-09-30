@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — deck playable lists")
struct AppModelDeckPlayableListTests {
    private struct DeckFixture: Decodable {
        let deck: Deck
    }

    private func sampleDeck() throws -> Deck {
        let url = try #require(
            Bundle.module.url(
                forResource: "decks", withExtension: "json", subdirectory: "Fixtures/Contract"
            )
        )
        return try ContractJSON.decode(DeckFixture.self, from: Data(contentsOf: url)).deck
    }

    private func renamedDeck(_ deck: Deck, name: String) -> Deck {
        let list = DeckList(
            slots: deck.list.slots,
            sideSlots: deck.list.sideSlots,
            investigatorCode: deck.list.investigatorCode,
            investigatorName: deck.list.investigatorName,
            meta: deck.list.meta,
            tabooId: deck.list.tabooId,
            url: deck.list.url,
            id: deck.list.id,
            name: name
        )
        return Deck(
            id: DeckID(UUID()),
            userId: deck.userId,
            url: deck.url,
            name: name,
            investigatorName: deck.investigatorName,
            list: list
        )
    }

    @Test("chooseDeck submits the specific deck the caller selected")
    func chooseDeckSubmitsSelectedDeck() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let first = try sampleDeck()
        let second = renamedDeck(first, name: "Selected deck")
        await service.enqueueChooseDeckResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.chooseDeck(second, investigatorId: "01001", in: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value

        let sentRequest = try #require(await service.lastChooseDeckRequest)
        #expect(sentRequest.deckList == DeckListInput(second.list))
    }

    @Test("chooseDeck sends playList instead of list when a 0.1.46 deck provides one")
    func chooseSavedDeckUsesPlayableList() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let deck = try sampleDeck()
        let playList = try DeckList(
            slots: CardQuantityMap([CardCode("c01016"): 1]),
            sideSlots: deck.list.sideSlots,
            investigatorCode: deck.list.investigatorCode,
            investigatorName: deck.list.investigatorName,
            meta: deck.list.meta,
            tabooId: deck.list.tabooId,
            url: deck.list.url,
            id: deck.list.id,
            name: deck.list.name
        )
        let deckWithPlayList = Deck(
            id: deck.id,
            userId: deck.userId,
            url: deck.url,
            name: deck.name,
            investigatorName: deck.investigatorName,
            list: deck.list,
            playList: playList
        )
        await service.enqueueChooseDeckResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.chooseDeck(deckWithPlayList, investigatorId: "01001", in: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value

        let sentRequest = try #require(await service.lastChooseDeckRequest)
        #expect(sentRequest.deckList == DeckListInput(playList))
    }
}
