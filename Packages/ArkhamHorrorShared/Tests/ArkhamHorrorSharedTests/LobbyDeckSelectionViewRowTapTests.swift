@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("LobbyDeckSelectionView — row tap")
struct LobbyDeckSelectionViewRowTapTests {
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

    @Test("Tapping a lobby deck row chooses that deck for its claimed investigator")
    func tappingLobbyDeckRowChoosesDeck() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = try GameID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000123")
        ))
        let deck = try sampleDeck()
        await service.enqueueChooseDeckResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        let view = LobbyDeckSelectionView(
            model: model,
            profile: .hosted,
            gameID: gameID,
            investigators: [InvestigatorSummary(id: "01001", classSymbol: .guardian)],
            action: nil
        )

        view.performLobbyDeckRowTapForTesting(deck: deck, investigatorID: "01001")
        await model.gameLifecycleActionTasks[gameID]?.value
        await model.gameListTask?.value

        let sentRequest = try #require(await service.lastChooseDeckRequest)
        #expect(sentRequest.investigatorId.rawValue == "01001")
        #expect(sentRequest.deckUrl == "https://arkhamdb.com/decklist/view/4242")
        #expect(sentRequest.deckList == DeckListInput(deck.list))
        let rowIdentifier = AccountAccessibilityID.lobbyDeckButton(
            for: gameID.rawValue,
            deckID: deck.id.rawValue
        )
        let expectedIdentifier = "account.games.chooseDeck.\(gameID.rawValue.uuidString)"
            + ".\(deck.id.rawValue.uuidString)"
        #expect(rowIdentifier == expectedIdentifier)
    }
}
