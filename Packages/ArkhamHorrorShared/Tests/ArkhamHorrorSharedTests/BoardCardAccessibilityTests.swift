@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Board card accessibility and badges")
struct BoardCardAccessibilityTests {
    private let playerID = BoardTestFixtures.playerID("000000000801")

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
            enemyValues: [enemyID: enemyWithDamageToken(#require(enemyValues[enemyID]))]
        ))
        let enemy = try #require(projection.enemiesByLocationID[locationID]?.first)
        let summary = BoardAccessibility.summary(enemy: enemy)
        #expect(summary.contains("Card c01159"))
        #expect(summary.contains("Fight 1"))
        #expect(summary.contains("Health 1"))
        #expect(summary.contains("Evade 3"))
        #expect(summary.contains("Damage taken 2"))
        #expect(summary.contains("Attack damage 1"))
        #expect(!summary.contains("Damage 1"))
        #expect(!summary.contains("Damage 2"))
    }

    @Test("Enemy accessibility can announce engaged investigator display name")
    func enemyAccessibilityUsesEngagedInvestigatorDisplayName() throws {
        let enemyID = EnemyActionFixtures.enemyID
        let investigatorID = BoardTestFixtures.investigatorID("c01002")
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    name: CardName(title: "Skids O'Toole", subtitle: nil),
                    engagedEnemies: [enemyID]
                ),
            ],
            playerOrder: [investigatorID],
            activeInvestigatorID: investigatorID,
            enemyValues: [enemyID: .null]
        ))
        let enemy = try #require(projection.engagedEnemiesByInvestigatorID[investigatorID]?.first)
        let summary = BoardAccessibility.summary(
            enemy: enemy,
            engagedInvestigatorName: projection.investigators.first?.displayName
        )

        #expect(summary.contains("Engaged with Skids O'Toole"))
        #expect(!summary.contains("Engaged with c01002"))
    }

    @Test("Threat treachery accessibility does not duplicate clue tokens")
    func threatTreacheryAccessibilityDoesNotDuplicateClues() {
        let treachery = BoardThreatTreacheryNode(
            id: BoardTestFixtures.treacheryID("00000000-0000-0000-0000-000000000711"),
            cardCode: BoardTestFixtures.cardCode("c01007"),
            displayName: "Card c01007",
            ownerID: playerID,
            clueCount: 2,
            tokenCounts: [
                BoardTokenSummary(token: "Clue", count: 2),
                BoardTokenSummary(token: "Doom", count: 1),
            ]
        )
        let summary = BoardAccessibility.summary(threatTreachery: treachery)

        #expect(summary.contains("Clues 2"))
        #expect(!summary.contains("Clue 2"))
        #expect(summary.contains("Doom 1"))
    }

    @Test("Player card badges do not duplicate use-token badges")
    func playerCardBadgesDoNotDuplicateUses() {
        let card = BoardPlayerCardNode(
            id: .asset(BoardTestFixtures.assetID("000000000611")),
            cardID: nil,
            cardCode: BoardTestFixtures.cardCode("c01018"),
            displayName: "Card c01018",
            subtitle: nil,
            zone: .asset,
            ownerID: playerID,
            damage: 1,
            horror: nil,
            usesSummary: "Ammo 3, Resource 1",
            tokenCounts: [
                BoardTokenSummary(token: "Ammo", count: 3),
                BoardTokenSummary(token: "Damage", count: 1),
                BoardTokenSummary(token: "Resource", count: 1),
            ],
            imageReference: nil
        )

        #expect(BoardCardBadgeFormatter.cardBadges(card) == [
            "Ammo 3, Resource 1",
            "Damage 1",
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

    private func enemyWithDamageToken(_ raw: JSONValue) -> JSONValue {
        guard case var .object(object) = raw else { return raw }
        object["tokens"] = .array([.array([.string("Damage"), number(2)])])
        return .object(object)
    }

    private func number(_ value: Int64) -> JSONValue {
        .number(.integer(value))
    }
}
