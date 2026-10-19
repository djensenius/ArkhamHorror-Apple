@testable import ArkhamHorrorShared
import Foundation
import Testing

private struct DeckSyncChoiceFixture: Decodable {
    let deck: Deck
}

func deckSyncChoiceSampleDeck() throws -> Deck {
    let url = try #require(
        Bundle.module.url(
            forResource: "decks", withExtension: "json", subdirectory: "Fixtures/Contract"
        )
    )
    return try ContractJSON.decode(DeckSyncChoiceFixture.self, from: Data(contentsOf: url)).deck
}

func deckSyncChoiceModifiedDeck(
    _ source: Deck,
    url: String?,
    name: String,
    listName: String? = nil
) -> Deck {
    let updatedList = DeckList(
        slots: source.list.slots,
        sideSlots: source.list.sideSlots,
        investigatorCode: source.list.investigatorCode,
        investigatorName: source.list.investigatorName,
        meta: source.list.meta,
        tabooId: source.list.tabooId,
        url: url,
        id: source.list.id,
        name: listName ?? source.list.name
    )
    return Deck(
        id: source.id,
        userId: source.userId,
        url: url,
        name: name,
        investigatorName: source.investigatorName,
        list: updatedList,
        lastUsedAt: source.lastUsedAt,
        overlay: source.overlay,
        playList: nil
    )
}
