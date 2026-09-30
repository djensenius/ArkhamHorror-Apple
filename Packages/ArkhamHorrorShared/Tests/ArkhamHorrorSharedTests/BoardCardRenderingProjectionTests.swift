@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("BoardProjection — visible cards and enemies")
struct BoardCardRenderingProjectionTests {
    private let playerID = BoardTestFixtures.playerID("000000000801")
    private let investigatorID = BoardTestFixtures.investigatorID("c01001")

    @Test("Hand, in-play, threat-area, and enemy panels project from snapshot data")
    func visibleBoardEntitiesProject() throws {
        let getGame = try vendoredGetGameEnvelope()
        let fixturePlayerID = try #require(getGame.playerID)
        let fixtureInvestigatorID = try #require(getGame.game.investigators.keys.first)
        let cardID = BoardTestFixtures.cardID("000000000501")
        let assetID = BoardTestFixtures.assetID("000000000601")
        let treacheryID = BoardTestFixtures.treacheryID("00000000-0000-0000-0000-000000000701")
        let enemyID = BoardTestFixtures.enemyID("000000000388")
        let locationID = BoardTestFixtures.locationID("000000000111")
        let investigator = BoardTestFixtures.investigator(
            id: fixtureInvestigatorID,
            engagedEnemies: [enemyID],
            assets: [assetID],
            hand: [playerCard(id: cardID, code: "c01020", title: "Machete")],
            treacheries: [treacheryID],
            playerID: fixturePlayerID
        )
        let snapshot = BoardTestFixtures.snapshot(
            locations: [(
                locationID,
                .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: locationID, investigators: [fixtureInvestigatorID], enemies: [enemyID]
                ))
            )],
            investigators: [fixtureInvestigatorID: investigator],
            playerOrder: [fixtureInvestigatorID],
            enemyValues: [enemyID: .null],
            assetValues: [assetID: assetObject(id: assetID)],
            treacheryValues: [treacheryID: treacheryObject(id: treacheryID)],
            cardValues: [cardID: playerCard(id: cardID, code: "c01020", title: "Machete")]
        )

        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)

        try expectPlayerCards(in: projection, cardID: cardID, playerID: fixturePlayerID)
        try expectEnemies(
            in: projection,
            enemyID: enemyID,
            locationID: locationID,
            investigatorID: fixtureInvestigatorID
        )
    }

    @Test("Non-active investigator engaged enemies stay visible and linked from prompt")
    func nonActiveInvestigatorEngagedEnemyIsReachable() throws {
        let enemyID = EnemyActionFixtures.enemyID
        let activeID = BoardTestFixtures.investigatorID("c01001")
        let engagedID = BoardTestFixtures.investigatorID("c01002")
        let active = BoardTestFixtures.investigator(
            id: activeID,
            playerID: BoardTestFixtures.playerID("000000000101")
        )
        let engaged = BoardTestFixtures.investigator(
            id: engagedID,
            engagedEnemies: [enemyID],
            playerID: BoardTestFixtures.playerID("000000000001")
        )
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: [activeID: active, engagedID: engaged],
            playerOrder: [activeID, engagedID],
            activeInvestigatorID: activeID,
            enemyValues: [enemyID: .null]
        ))
        #expect(projection.engagedEnemiesByInvestigatorID[engagedID]?.first?.id == enemyID)

        let prompt = try EnemyActionFixtures.prompt()
        let links = BoardPromptChoiceLinker.links(prompt: prompt, projection: projection)
        #expect(links[.enemy(enemyID)]?.map(\.choiceIndex) == [4, 5])

        let graph = BoardFocusGraphBuilder.makeGraph(
            projection: projection,
            layout: BoardLayoutBuilder.makeLayout(locations: []),
            prompt: prompt
        )
        #expect(!graph.order.contains { $0.rawValue.hasPrefix("board.card.") })
        #expect(!graph.order.contains { $0.rawValue.hasPrefix("board.enemy.") })
        #expect(!graph.order.contains { $0.rawValue.hasPrefix("board.treachery.") })
        #expect(graph.zoneEntryPoints[BoardFocusZone.prompt] != nil)
        #expect(graph.contains(BoardFocusID.promptChoice(4)))
    }

    @Test("Full player area selection prefers prompt owner, local player, then active investigator")
    func fullPlayerAreaSelectionOrder() throws {
        let activeID = BoardTestFixtures.investigatorID("c01001")
        let localID = BoardTestFixtures.investigatorID("c01002")
        let promptID = BoardTestFixtures.investigatorID("c01003")
        let localPlayerID = BoardTestFixtures.playerID("000000000802")
        let promptPlayerID = BoardTestFixtures.playerID("000000000803")
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: [
                activeID: BoardTestFixtures.investigator(id: activeID, playerID: playerID),
                localID: BoardTestFixtures.investigator(id: localID, playerID: localPlayerID),
                promptID: BoardTestFixtures.investigator(id: promptID, playerID: promptPlayerID),
            ],
            playerOrder: [activeID, localID, promptID],
            activeInvestigatorID: activeID
        ))
        let active = try #require(projection.investigators.first { $0.id == activeID })
        let local = try #require(projection.investigators.first { $0.id == localID })
        let prompt = try #require(projection.investigators.first { $0.id == promptID })

        #expect(BoardPlayerAreaVisibility.shouldShowFullArea(
            for: prompt,
            fullPlayerAreaPlayerID: promptPlayerID
        ))
        #expect(!BoardPlayerAreaVisibility.shouldShowFullArea(
            for: local,
            fullPlayerAreaPlayerID: promptPlayerID
        ))
        #expect(BoardPlayerAreaVisibility.shouldShowFullArea(
            for: local,
            fullPlayerAreaPlayerID: localPlayerID
        ))
        #expect(BoardPlayerAreaVisibility.shouldShowFullArea(
            for: active,
            fullPlayerAreaPlayerID: nil
        ))
        #expect(!BoardPlayerAreaVisibility.shouldShowFullArea(
            for: local,
            fullPlayerAreaPlayerID: nil
        ))
    }

    @Test("Investigator display-name lookup tolerates repeated player order entries")
    func investigatorDisplayNameLookupToleratesRepeatedPlayerOrder() {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    name: CardName(title: "Roland Banks", subtitle: nil)
                ),
            ],
            playerOrder: [investigatorID, investigatorID],
            activeInvestigatorID: investigatorID
        ))

        #expect(projection.investigators.map(\.id) == [investigatorID, investigatorID])
        #expect(
            BoardInvestigatorDisplayNames.map(projection.investigators)[investigatorID]
                == "Roland Banks"
        )
    }

    @Test("Enemy calculation tags render display values")
    func enemyCalculationTagsRender() {
        #expect(calculation("Static", number(2), players: 3)?.displayValue == "2")
        #expect(calculation("PerPlayer", number(2), players: 3)?.displayValue == "6")
        #expect(
            calculation("StaticWithPerPlayer", numbers([1, 2]), players: 3)?.displayValue == "7"
        )
        #expect(
            calculation("ByPlayerCount", numbers([1, 2, 4, 8]), players: 3)?.displayValue == "4"
        )
        #expect(calculation("ValueX", nil, players: 3)?.displayValue == "X")
        #expect(calculation("ValueStar", nil, players: 3)?.displayValue == "–")
    }

    @Test("Enemy per-player calculations clamp instead of trapping on overflow")
    func enemyCalculationOverflowClamps() {
        let huge = Int64.max
        #expect(
            calculation("PerPlayer", number(huge), players: 2)?.staticValue == Int.max
        )
        #expect(
            calculation("StaticWithPerPlayer", numbers([huge, huge]), players: 2)?.staticValue
                == Int.max
        )
        let hugeNegative = (Int64.min / 2) - 1
        #expect(
            calculation("PerPlayer", number(hugeNegative), players: 3)?.staticValue == Int.min
        )
        #expect(
            calculation(
                "StaticWithPerPlayer", numbers([hugeNegative, hugeNegative]), players: 3
            )?.staticValue == Int.min
        )
    }

    @Test("Choice-to-board links require actionability and prompt submit authority")
    func choiceLinksHonorActionability() throws {
        let enemyID = EnemyActionFixtures.enemyID
        let prompt = try EnemyActionFixtures.prompt()
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            enemyValues: [enemyID: .null]
        ))
        let links = BoardPromptChoiceLinker.links(prompt: prompt, projection: projection)
        let enemyLinks = try #require(links[.enemy(enemyID)])
        #expect(enemyLinks.map(\.choiceIndex) == [4, 5])
        #expect(!enemyLinks.contains { !$0.isActionable })

        let missingEnemyProjection = BoardProjectionBuilder.makeProjection(
            from: BoardTestFixtures.snapshot()
        )
        let missingLinks = BoardPromptChoiceLinker.links(
            prompt: prompt, projection: missingEnemyProjection
        )
        #expect(missingLinks[.enemy(enemyID)]?.allSatisfy { !$0.isActionable } == true)

        let sendingPrompt = try EnemyActionFixtures.prompt(phase: .sending, actionChoiceIndex: 4)
        let sendingLinks = BoardPromptChoiceLinker.links(
            prompt: sendingPrompt, projection: projection
        )
        #expect(sendingLinks[.enemy(enemyID)]?.allSatisfy { !$0.isActionable } == true)
    }

    private func expectPlayerCards(
        in projection: BoardProjection,
        cardID: WireCardID,
        playerID: PlayerID
    ) throws {
        let hand = try #require(projection.orderedHandCardsByPlayer[playerID]?.first)
        #expect(hand.displayName == "Machete")
        #expect(hand.cardCode?.rawValue == "c01020")
        #expect(projection.handCardsByPlayer[playerID]?[cardID]?.displayLabel == "Machete")

        let asset = try #require(projection.inPlayCardsByPlayer[playerID]?.first)
        #expect(asset.displayName == "Card c01018")
        #expect(asset.usesSummary == "Ammo 3")
        #expect(asset.damage == 1)
        #expect(asset.horror == 2)

        let threat = try #require(projection.threatTreacheriesByPlayer[playerID]?.first)
        #expect(threat.displayName == "Card c01007")
        #expect(threat.clueCount == 1)
    }

    private func expectEnemies(
        in projection: BoardProjection,
        enemyID: EnemyID,
        locationID: LocationID,
        investigatorID: InvestigatorID
    ) throws {
        #expect(projection.enemiesByLocationID[locationID]?.isEmpty != false)

        let engagedEnemy = try #require(
            projection.engagedEnemiesByInvestigatorID[investigatorID]?.first
        )
        #expect(engagedEnemy.id == enemyID)
        #expect(engagedEnemy.engagedInvestigatorID == investigatorID)
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

    private func vendoredGetGameEnvelope() throws -> GetGameEnvelope {
        let url = try #require(Bundle.module.url(
            forResource: "get-game",
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        return try ContractJSON.decode(GetGameEnvelope.self, from: Data(contentsOf: url))
    }

    private func assetObject(id: AssetID) -> JSONValue {
        .object([
            "id": .string(id.codingKey.stringValue),
            "cardId": .string(BoardTestFixtures.cardID("000000000602").codingKey.stringValue),
            "cardCode": .string("c01018"),
            "tokens": .array([
                .array([.string("Ammo"), number(3)]),
                .array([.string("Damage"), number(1)]),
                .array([.string("Horror"), number(2)]),
            ]),
        ])
    }

    private func treacheryObject(id: TreacheryID) -> JSONValue {
        .object([
            "id": .string(id.codingKey.stringValue),
            "cardCode": .string("c01007"),
            "tokens": .array([.array([.string("Clue"), number(1)])]),
        ])
    }

    private func calculation(
        _ tag: String, _ contents: JSONValue?, players: Int
    ) -> BoardCalculationSummary? {
        BoardProjectionBuilder.calculationSummary(
            in: .object([
                "tag": .string("GameValueCalculation"),
                "contents": .object([
                    "tag": .string(tag),
                    "contents": contents ?? .null,
                ]),
            ]),
            playerCount: players
        )
    }

    private func numbers(_ values: [Int64]) -> JSONValue {
        .array(values.map(number))
    }

    private func number(_ value: Int64) -> JSONValue {
        .number(.integer(value))
    }
}
