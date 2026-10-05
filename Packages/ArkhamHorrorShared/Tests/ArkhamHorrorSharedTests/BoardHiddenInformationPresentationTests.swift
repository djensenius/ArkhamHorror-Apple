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
        let hiddenHandBacks = BoardPlayerAreaVisibility.hiddenHandBackPlaceholders(
            for: other,
            localPlayerID: fixture.localPlayerID,
            isSolo: false
        )
        #expect(hiddenHandBacks.count == other.handCount)
        #expect(hiddenHandBacks.map(\.accessibilityLabel) == ["Hidden hand card"])
        #expect(hiddenHandBacks.allSatisfy { $0.cardID == nil })
        #expect(BoardPlayerAreaVisibility.hiddenHandBackPlaceholders(
            for: local,
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
        #expect(BoardPlayerAreaVisibility.shouldShowFullArea(
            for: local,
            fullPlayerAreaPlayerID: fixture.localPlayerID,
            isSolo: false
        ))
        let fullAreaDeckBadge = BoardPlayerAreaVisibility.deckCountBadge(for: local)
        #expect(fullAreaDeckBadge.count == local.deckCount)
        #expect(fullAreaDeckBadge.value == "1")
        #expect(fullAreaDeckBadge.accessibilityLabel == "Deck 1 card")
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
        let projectedCardIDs = Set(
            allProjectedPlayerCards.compactMap { $0.cardID?.codingKey.stringValue }
        )
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
}

struct MultiplayerHiddenFixture {
    let envelope: GetGameEnvelope
    let localPlayerID: PlayerID
    let otherPlayerID: PlayerID
    let localInvestigatorID: InvestigatorID
    let otherInvestigatorID: InvestigatorID
    let otherDeckTopID: WireCardID
    let otherDeckBottomID: WireCardID
}

struct MultiplayerHiddenCards {
    let localCardID: WireCardID
    let otherCardID: WireCardID
    let otherDeckTopID: WireCardID
    let otherDeckBottomID: WireCardID
    let localHand: JSONValue
    let otherHand: JSONValue
    let otherDeckTop: JSONValue
    let otherDeckBottom: JSONValue
}
