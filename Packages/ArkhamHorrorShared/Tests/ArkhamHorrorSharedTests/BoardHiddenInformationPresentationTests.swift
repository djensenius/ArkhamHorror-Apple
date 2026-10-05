@testable import ArkhamHorrorShared
import Testing

@Suite("BoardProjection — hidden multiplayer information")
struct BoardHiddenInformationPresentationTests {
    @Test(
        "Multiplayer presentation hides other players' hand faces and deck order"
    )
    func multiplayerHiddenInformationPresentation() throws {
        let fixture = try multiplayerFixture()
        let decoded = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: ContractJSON.encode(fixture.envelope)
        )
        #expect(decoded.multiplayerMode == .withFriends)

        let projection = BoardProjectionBuilder.makeProjection(from: decoded.game)
        let local = try #require(projection.investigators.first {
            $0.id == fixture.localInvestigatorID
        })
        let other = try #require(projection.investigators.first {
            $0.id == fixture.otherInvestigatorID
        })

        assertResolvedButHidden(
            projection: projection,
            local: local,
            other: other,
            fixture: fixture
        )
        assertSoloStillRevealsOwnMultihand(
            projection: projection,
            other: other,
            fixture: fixture
        )
        assertOnlyCountsSurvive(projection: projection, other: other, fixture: fixture)
    }

    private func assertResolvedButHidden(
        projection: BoardProjection,
        local: BoardInvestigatorNode,
        other: BoardInvestigatorNode,
        fixture: MultiplayerHiddenFixture
    ) {
        #expect(projection.orderedHandCardsByPlayer[fixture.otherPlayerID]?.map(\.displayName) == [
            "Forbidden Knowledge",
        ])
        #expect(BoardPlayerAreaVisibility.visibleHandCards(
            for: other,
            cardsByPlayer: projection.orderedHandCardsByPlayer,
            localPlayerID: fixture.localPlayerID,
            isSolo: false
        ).isEmpty)
        #expect(BoardPlayerAreaVisibility.visibleHandCards(
            for: local,
            cardsByPlayer: projection.orderedHandCardsByPlayer,
            localPlayerID: fixture.localPlayerID,
            isSolo: false
        ).map(\.displayName) == ["Machete"])
        #expect(BoardCommandController.fullPlayerAreaPlayerID(
            promptOwnerID: fixture.otherPlayerID,
            localPlayerID: fixture.localPlayerID,
            activeInvestigatorPlayerID: fixture.otherPlayerID,
            isSolo: false
        ) == fixture.localPlayerID)
        #expect(!BoardPlayerAreaVisibility.shouldShowFullArea(
            for: other,
            fullPlayerAreaPlayerID: fixture.localPlayerID,
            isSolo: false
        ))
    }

    private func assertSoloStillRevealsOwnMultihand(
        projection: BoardProjection,
        other: BoardInvestigatorNode,
        fixture: MultiplayerHiddenFixture
    ) {
        #expect(BoardPlayerAreaVisibility.visibleHandCards(
            for: other,
            cardsByPlayer: projection.orderedHandCardsByPlayer,
            localPlayerID: fixture.localPlayerID,
            isSolo: true
        ).map(\.displayName) == ["Forbidden Knowledge"])
    }

    private func assertOnlyCountsSurvive(
        projection: BoardProjection,
        other: BoardInvestigatorNode,
        fixture: MultiplayerHiddenFixture
    ) {
        #expect(other.handCount == 1)
        #expect(other.deckCount == 2)
        let renderedPlayerCardCodes = projection
            .orderedHandCardsByPlayer[fixture.localPlayerID, default: []]
            .compactMap { $0.cardCode?.rawValue }
            + BoardPlayerAreaVisibility.visibleHandCards(
                for: other,
                cardsByPlayer: projection.orderedHandCardsByPlayer,
                localPlayerID: fixture.localPlayerID,
                isSolo: false
            ).compactMap { $0.cardCode?.rawValue }
        #expect(!renderedPlayerCardCodes.contains("c01016"))
        #expect(!renderedPlayerCardCodes.contains("c01998"))
        #expect(!renderedPlayerCardCodes.contains("c01999"))
    }

    private func multiplayerFixture() throws -> MultiplayerHiddenFixture {
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
        let envelope = GetGameEnvelope(
            playerID: localPlayerID,
            multiplayerMode: .withFriends,
            game: snapshot,
            eventID: nil
        )
        return MultiplayerHiddenFixture(
            envelope: envelope,
            localPlayerID: localPlayerID,
            otherPlayerID: otherPlayerID,
            localInvestigatorID: localInvestigatorID,
            otherInvestigatorID: otherInvestigatorID
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
            ],
            playerCount: 2
        )
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

private struct MultiplayerHiddenFixture {
    let envelope: GetGameEnvelope
    let localPlayerID: PlayerID
    let otherPlayerID: PlayerID
    let localInvestigatorID: InvestigatorID
    let otherInvestigatorID: InvestigatorID
}

private struct MultiplayerHiddenCards {
    let localCardID: WireCardID
    let otherCardID: WireCardID
    let localHand: JSONValue
    let otherHand: JSONValue
    let otherDeckTop: JSONValue
    let otherDeckBottom: JSONValue
}
