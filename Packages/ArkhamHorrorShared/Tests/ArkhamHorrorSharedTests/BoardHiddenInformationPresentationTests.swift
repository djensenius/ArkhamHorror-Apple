@testable import ArkhamHorrorShared
import Foundation
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
        try assertPromptGuardHidesOtherPlayerHandCardTitle(
            bytes: ContractJSON.encode(fixture.envelope),
            fixture: fixture
        )
        assertLiveDefaultsDoNotRevealWithoutModeOptIn(other: other)
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
        let allProjectedPlayerCards = projection.orderedHandCardsByPlayer.values.flatMap(\.self)
            + projection.inPlayCardsByPlayer.values.flatMap(\.self)
        let projectedCardCodes = Set(allProjectedPlayerCards.compactMap { $0.cardCode?.rawValue })
        let projectedCardIDs = Set(allProjectedPlayerCards.compactMap { $0.cardID?.codingKey.stringValue })
        #expect(!projectedCardCodes.contains("c01998"))
        #expect(!projectedCardCodes.contains("c01999"))
        #expect(!projectedCardIDs.contains(fixture.otherDeckTopID.codingKey.stringValue))
        #expect(!projectedCardIDs.contains(fixture.otherDeckBottomID.codingKey.stringValue))
    }

    private func assertPromptGuardHidesOtherPlayerHandCardTitle(
        bytes: Data,
        fixture: MultiplayerHiddenFixture
    ) throws {
        #expect(bytes.range(of: Data("Forbidden Knowledge".utf8)) != nil)
        let decoded = try ContractJSON.decode(GetGameEnvelope.self, from: bytes)
        let projection = BoardProjectionBuilder.makeProjection(from: decoded.game)
        let payload = try #require(decoded.game.question[fixture.otherPlayerID])
        let prompt = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: decoded.game.id,
                ownerID: fixture.otherPlayerID,
                questionVersion: decoded.game.scenarioSteps,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            readOnlyReason: .spectator,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        let choice = try #require(prompt.choices.first)
        let revealsFaces = prompt.revealsHandCardFaces(
            in: projection,
            localPlayerID: nil,
            isSolo: false
        )
        #expect(!revealsFaces)
        let resolved = prompt.resolvedChoiceLabel(
            for: choice,
            in: projection,
            revealsHandCardFaces: revealsFaces
        )
        #expect(resolved.title == "Replace hidden card")
        #expect(!resolved.title.contains("Forbidden Knowledge"))
        #expect(resolved.systemImage == "rectangle.portrait")
    }

    private func assertLiveDefaultsDoNotRevealWithoutModeOptIn(
        other: BoardInvestigatorNode
    ) {
        #expect(!BoardPlayerAreaVisibility.shouldShowFullArea(
            for: other,
            fullPlayerAreaPlayerID: nil
        ))
        #expect(BoardCommandController.fullPlayerAreaPlayerID(
            promptOwnerID: other.playerID,
            localPlayerID: nil,
            activeInvestigatorPlayerID: other.playerID
        ) == nil)
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

private struct MultiplayerHiddenFixture {
    let envelope: GetGameEnvelope
    let localPlayerID: PlayerID
    let otherPlayerID: PlayerID
    let localInvestigatorID: InvestigatorID
    let otherInvestigatorID: InvestigatorID
    let otherDeckTopID: WireCardID
    let otherDeckBottomID: WireCardID
}

private struct MultiplayerHiddenCards {
    let localCardID: WireCardID
    let otherCardID: WireCardID
    let otherDeckTopID: WireCardID
    let otherDeckBottomID: WireCardID
    let localHand: JSONValue
    let otherHand: JSONValue
    let otherDeckTop: JSONValue
    let otherDeckBottom: JSONValue
}
