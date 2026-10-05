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

    @Test("Hidden hand fan layout stays inside the investigator tile")
    func hiddenHandFanLayoutStaysInsideTile() {
        let tileWidth: CGFloat = 272
        let cases = [
            HiddenHandFanLayoutCase(handCount: 0, expectedWidth: 0, spacingIsNegative: false),
            HiddenHandFanLayoutCase(handCount: 3, expectedWidth: 104, spacingIsNegative: false),
            HiddenHandFanLayoutCase(
                handCount: 8, expectedWidth: tileWidth, spacingIsNegative: false
            ),
            HiddenHandFanLayoutCase(
                handCount: 12, expectedWidth: tileWidth, spacingIsNegative: true
            ),
        ]

        for testCase in cases {
            let layout = BoardHiddenHandBackFanLayout.make(
                handCount: testCase.handCount,
                availableWidth: tileWidth
            )
            #expect(layout.totalWidth <= tileWidth)
            #expect(layout.totalWidth == testCase.expectedWidth)
            #expect((layout.spacing < 0) == testCase.spacingIsNegative)
        }
    }

    @Test("Hidden hand placeholders cover empty and multi-card hands")
    func hiddenHandPlaceholdersCoverEmptyAndMultiCardHands() {
        let localPlayerID = BoardTestFixtures.playerID("000000000801")
        let otherPlayerID = BoardTestFixtures.playerID("000000000802")

        let emptyHandBacks = BoardPlayerAreaVisibility.hiddenHandBackPlaceholders(
            for: hiddenInformationInvestigatorNode(handCount: 0, playerID: otherPlayerID),
            localPlayerID: localPlayerID,
            isSolo: false
        )
        #expect(emptyHandBacks.isEmpty)

        let threeHandBacks = BoardPlayerAreaVisibility.hiddenHandBackPlaceholders(
            for: hiddenInformationInvestigatorNode(handCount: 3, playerID: otherPlayerID),
            localPlayerID: localPlayerID,
            isSolo: false
        )
        #expect(threeHandBacks.map(\.id) == [0, 1, 2])
        #expect(threeHandBacks.map(\.accessibilityLabel) == [
            "Hidden hand card", "Hidden hand card", "Hidden hand card",
        ])
        #expect(BoardPlayerAreaVisibility.hiddenHandBackPlaceholders(
            for: hiddenInformationInvestigatorNode(handCount: 3, playerID: localPlayerID),
            localPlayerID: localPlayerID,
            isSolo: false
        ).isEmpty)
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

private struct HiddenHandFanLayoutCase {
    let handCount: Int
    let expectedWidth: CGFloat
    let spacingIsNegative: Bool
}

private func hiddenInformationInvestigatorNode(
    handCount: Int,
    playerID: PlayerID,
    id: InvestigatorID = BoardTestFixtures.investigatorID("c01001")
) -> BoardInvestigatorNode {
    BoardInvestigatorNode(
        id: id,
        playerID: playerID,
        displayName: "Roland Banks",
        subtitle: nil,
        investigatorClass: .guardian,
        health: 9,
        sanity: 5,
        remainingActions: 3,
        experiencePoints: 0,
        spentExperience: 0,
        physicalTrauma: 0,
        mentalTrauma: 0,
        unhealedHorrorThisRound: 0,
        assignedHealthDamage: 0,
        assignedSanityDamage: 0,
        defeated: false,
        resigned: false,
        eliminated: false,
        killed: false,
        drivenInsane: false,
        currentLocationID: nil,
        isActiveInvestigator: false,
        isActingPlayer: false,
        isTurnPlayer: false,
        isLeadInvestigator: false,
        handCount: handCount,
        deckCount: 0,
        isMultiplayer: true,
        hasPendingPrompt: false,
        engagedEnemyCount: 0,
        assetCount: 0,
        eventCount: 0,
        treacheryCount: 0,
        skillCount: 0,
        scarletKeyCount: 0,
        tokenCounts: [],
        movementSummary: nil,
        placementSummary: "No location"
    )
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
