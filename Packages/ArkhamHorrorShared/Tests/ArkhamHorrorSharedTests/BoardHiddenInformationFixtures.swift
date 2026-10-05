@testable import ArkhamHorrorShared

extension BoardHiddenInformationPresentationTests {
    func multiplayerFixture() throws -> MultiplayerHiddenFixture {
        let localPlayerID = BoardTestFixtures.playerID("000000000811")
        let otherPlayerID = BoardTestFixtures.playerID("000000000812")
        let localInvestigatorID = BoardTestFixtures.investigatorID("c01001")
        let otherInvestigatorID = BoardTestFixtures.investigatorID("c01002")
        let cards = multiplayerCards()
        let snapshot = multiplayerSnapshot(
            localPlayerID: localPlayerID,
            otherPlayerID: otherPlayerID,
            localInvestigatorID: localInvestigatorID,
            otherInvestigatorID: otherInvestigatorID,
            cards: cards
        )
        let game = try addChooseHandCardQuestion(
            to: snapshot,
            ownerID: otherPlayerID,
            cardID: cards.otherCardID
        )
        let envelope = GetGameEnvelope(
            playerID: localPlayerID,
            multiplayerMode: .withFriends,
            game: game,
            eventID: nil
        )
        return MultiplayerHiddenFixture(
            envelope: envelope,
            localPlayerID: localPlayerID,
            otherPlayerID: otherPlayerID,
            localInvestigatorID: localInvestigatorID,
            otherInvestigatorID: otherInvestigatorID,
            otherDeckTopID: cards.otherDeckTopID,
            otherDeckBottomID: cards.otherDeckBottomID
        )
    }

    private func multiplayerCards() -> MultiplayerHiddenCards {
        let localCardID = BoardTestFixtures.cardID("000000000521")
        let otherCardID = BoardTestFixtures.cardID("000000000522")
        let otherDeckTopID = BoardTestFixtures.cardID("000000000523")
        let otherDeckBottomID = BoardTestFixtures.cardID("000000000524")
        return MultiplayerHiddenCards(
            localCardID: localCardID,
            otherCardID: otherCardID,
            otherDeckTopID: otherDeckTopID,
            otherDeckBottomID: otherDeckBottomID,
            localHand: playerCard(id: localCardID, code: "c01020", title: "Machete"),
            otherHand: playerCard(
                id: otherCardID, code: "c01016", title: "Forbidden Knowledge"
            ),
            otherDeckTop: playerCard(
                id: otherDeckTopID, code: "c01998", title: "Other Deck Top"
            ),
            otherDeckBottom: playerCard(
                id: otherDeckBottomID, code: "c01999", title: "Other Deck Bottom"
            )
        )
    }

    private func multiplayerSnapshot(
        localPlayerID: PlayerID,
        otherPlayerID: PlayerID,
        localInvestigatorID: InvestigatorID,
        otherInvestigatorID: InvestigatorID,
        cards: MultiplayerHiddenCards
    ) -> PublicGameSnapshot {
        BoardTestFixtures.snapshot(
            investigators: [
                localInvestigatorID: BoardTestFixtures.investigator(
                    id: localInvestigatorID,
                    hand: [cards.localHand],
                    deckSize: 1,
                    playerID: localPlayerID
                ),
                otherInvestigatorID: BoardTestFixtures.investigator(
                    id: otherInvestigatorID,
                    hand: [cards.otherHand],
                    deck: [cards.otherDeckTop, cards.otherDeckBottom],
                    deckSize: 2,
                    playerID: otherPlayerID
                ),
            ],
            playerOrder: [localInvestigatorID, otherInvestigatorID],
            activeInvestigatorID: otherInvestigatorID,
            cardValues: [
                cards.localCardID: cards.localHand,
                cards.otherCardID: cards.otherHand,
                cards.otherDeckTopID: cards.otherDeckTop,
                cards.otherDeckBottomID: cards.otherDeckBottom,
            ],
            playerCount: 2
        )
    }

    private func addChooseHandCardQuestion(
        to snapshot: PublicGameSnapshot,
        ownerID: PlayerID,
        cardID: WireCardID
    ) throws -> PublicGameSnapshot {
        var value = try ContractJSON.decode(JSONValue.self, from: ContractJSON.encode(snapshot))
        guard case var .object(root) = value else { throw TestFailure() }
        root["question"] = .object([
            ownerID.rawValue.uuidString.lowercased(): chooseHandCardQuestion(cardID: cardID),
        ])
        value = .object(root)
        return try ContractJSON.decode(PublicGameSnapshot.self, from: ContractJSON.encode(value))
    }

    private func chooseHandCardQuestion(cardID: WireCardID) -> JSONValue {
        .object([
            "tag": .string("ChooseOne"),
            "choices": .array([
                .object([
                    "tag": .string("TargetLabel"),
                    "target": .object([
                        "tag": .string("CardIdTarget"),
                        "contents": .string(cardID.codingKey.stringValue),
                    ]),
                    "messages": .array([.object(["tag": .string("NoOp")])]),
                ]),
                .object([
                    "tag": .string("Label"),
                    "label": .string("$label.doneWithMulligan"),
                    "messages": .array([.object(["tag": .string("NoOp")])]),
                ]),
            ]),
        ])
    }

    private func playerCard(id: WireCardID, code: String, title: String) -> JSONValue {
        .object([
            "tag": .string("PlayerCard"),
            "contents": .object([
                "id": .string(id.codingKey.stringValue),
                "cardCode": .string(code),
                "name": .object(["title": .string(title)]),
            ]),
        ])
    }
}
