@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("BoardProjection — visible cards and enemies")
struct BoardCardRenderingProjectionTests {
    private let playerID = BoardTestFixtures.playerID("000000000801")
    private let investigatorID = BoardTestFixtures.investigatorID("c01001")

    @Test("Hand, in-play, threat-area, and enemy panels project from snapshot data")
    func visibleBoardEntitiesProject() throws {
        let cardID = BoardTestFixtures.cardID("000000000501")
        let assetID = BoardTestFixtures.assetID("000000000601")
        let treacheryID = BoardTestFixtures.treacheryID("00000000-0000-0000-0000-000000000701")
        let enemyID = BoardTestFixtures.enemyID("000000000388")
        let locationID = BoardTestFixtures.locationID("000000000111")
        let investigator = BoardTestFixtures.investigator(
            id: investigatorID,
            engagedEnemies: [enemyID],
            assets: [assetID],
            hand: [playerCard(id: cardID, code: "c01020", title: "Machete")],
            treacheries: [treacheryID],
            playerID: playerID
        )
        let snapshot = BoardTestFixtures.snapshot(
            locations: [(
                locationID,
                .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: locationID, investigators: [investigatorID], enemies: [enemyID]
                ))
            )],
            investigators: [investigatorID: investigator],
            playerOrder: [investigatorID],
            enemyValues: [enemyID: .null],
            assetValues: [assetID: assetObject(id: assetID)],
            treacheryValues: [treacheryID: treacheryObject(id: treacheryID)],
            cardValues: [cardID: playerCard(id: cardID, code: "c01020", title: "Machete")]
        )

        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)

        try expectPlayerCards(in: projection, cardID: cardID)
        try expectEnemies(in: projection, enemyID: enemyID, locationID: locationID)
    }

    @Test("Enemy accessibility label includes stats and state")
    func enemyAccessibilitySummaryIncludesStats() throws {
        let enemyValues = try vendoredEnemyEntityMap()
        let enemyID = try #require(enemyValues.keys.first)
        let locationID = BoardTestFixtures.locationID("000000000112")
        let projection = try BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: [(
                locationID,
                .ordinary(BoardTestFixtures.ordinaryLocation(id: locationID, enemies: [enemyID]))
            )],
            enemyValues: [enemyID: #require(enemyValues[enemyID])]
        ))
        let enemy = try #require(projection.enemiesByLocationID[locationID]?.first)
        let summary = BoardAccessibility.summary(enemy: enemy)
        #expect(summary.contains("Card c01159"))
        #expect(summary.contains("Fight 1"))
        #expect(summary.contains("Health 1"))
        #expect(summary.contains("Evade 3"))
        #expect(summary.contains("Damage 1"))
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
        #expect(enemyLinks.allSatisfy(\.isActionable))

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

    private func expectPlayerCards(in projection: BoardProjection, cardID: WireCardID) throws {
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
        #expect(threat.displayName == "Cover Up")
        #expect(threat.clueCount == 1)
    }

    private func expectEnemies(
        in projection: BoardProjection,
        enemyID: EnemyID,
        locationID: LocationID
    ) throws {
        let locationEnemy = try #require(projection.enemiesByLocationID[locationID]?.first)
        #expect(locationEnemy.displayName.hasPrefix("Enemy"))
        #expect(locationEnemy.fight == nil)
        #expect(locationEnemy.health == nil)
        #expect(locationEnemy.evade == nil)

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

    private func vendoredEnemyEntityMap() throws -> UUIDEntityMap<EnemyIDTag> {
        let url = try #require(Bundle.module.url(
            forResource: "uuid-entity-map",
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        return try ContractJSON.decode(
            UUIDEntityMap<EnemyIDTag>.self,
            from: Data(contentsOf: url)
        )
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
            "name": .string("Cover Up"),
            "tokens": .array([.array([.string("Clue"), number(1)])]),
        ])
    }

    private func number(_ value: Int64) -> JSONValue {
        .number(.integer(value))
    }
}
