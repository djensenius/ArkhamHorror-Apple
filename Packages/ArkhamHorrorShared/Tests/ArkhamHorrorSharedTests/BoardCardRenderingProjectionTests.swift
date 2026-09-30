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
    }

    @Test("Choice-to-board links include hand, in-play, treachery, and semantic entities")
    func choiceLinksCoverCardEntityPaths() {
        let cardID = BoardTestFixtures.cardID("000000000521")
        let assetID = BoardTestFixtures.assetID("000000000621")
        let treacheryID = BoardTestFixtures.treacheryID("00000000-0000-0000-0000-000000000721")
        let investigator = BoardTestFixtures.investigator(
            id: investigatorID,
            assets: [assetID],
            hand: [playerCard(id: cardID, code: "c01020", title: "Machete")],
            treacheries: [treacheryID],
            playerID: playerID
        )
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: [investigatorID: investigator],
            playerOrder: [investigatorID],
            activeInvestigatorID: investigatorID,
            assetValues: [assetID: assetObject(id: assetID)],
            treacheryValues: [treacheryID: treacheryObject(id: treacheryID)],
            cardValues: [cardID: playerCard(id: cardID, code: "c01020", title: "Machete")]
        ))
        let choices = [
            BasicChoice(
                index: 0,
                rawValue: .string("hand"),
                content: .chooseHandCard(cardID: cardID, purpose: .choose, messages: [])
            ),
            BasicChoice(
                index: 1,
                rawValue: .string("treachery"),
                content: .resolveForcedAbility(ForcedAbilityChoice(
                    ability: ability(cardCode: "c01007"),
                    treacheryID: treacheryID
                ))
            ),
            BasicChoice(
                index: 2,
                rawValue: .string("semantic-asset"),
                content: .gainResource(investigatorID: investigatorID, messages: [])
            ),
        ]
        let semantic = BoundQuestionPresentation(
            presentation: QuestionPresentation(
                protocolVersion: QuestionPresentation.supportedProtocolVersion,
                questionVersion: 1,
                questionKind: .chooseOne,
                choiceCount: choices.count,
                choices: [QuestionPresentation.Choice(
                    sourceIndex: 2,
                    kind: .useAbility,
                    actorID: investigatorID.rawValue.rawValue,
                    entity: .init(kind: .asset, id: assetID.codingKey.stringValue),
                    label: nil,
                    ability: nil,
                    cost: nil
                )]
            ),
            rawChoices: choices.map(\.rawValue),
            governedSource: nil
        )
        let links = BoardPromptChoiceLinker.links(
            prompt: prompt(choices: choices, semanticPresentation: semantic),
            projection: projection
        )

        #expect(links[.playerCard(.card(cardID))]?.map(\.choiceIndex) == [0])
        #expect(links[.treachery(treacheryID)]?.map(\.choiceIndex) == [1])
        #expect(links[.playerCard(.asset(assetID))]?.map(\.choiceIndex) == [2])
    }

    @Test("Linked board choice presentation chooses highlight, submit, or menu")
    func linkedChoicePresentationDecision() {
        let first = BoardLinkedChoice(choiceIndex: 1, title: "First", isActionable: true)
        let second = BoardLinkedChoice(choiceIndex: 2, title: "Second", isActionable: true)
        let unavailable = BoardLinkedChoice(
            choiceIndex: 3,
            title: "Unavailable",
            isActionable: false
        )

        #expect(BoardLinkedChoicePresentationPolicy.decision(for: []) == .highlightOnly)
        #expect(
            BoardLinkedChoicePresentationPolicy.decision(for: [unavailable]) == .highlightOnly
        )
        #expect(BoardLinkedChoicePresentationPolicy.decision(for: [first]) == .submit(first))
        #expect(
            BoardLinkedChoicePresentationPolicy.decision(for: [first, unavailable, second])
                == .menu([first, second])
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

    private func prompt(
        choices: [BasicChoice],
        semanticPresentation: BoundQuestionPresentation? = nil
    ) -> BasicChoicePromptPresentation {
        let rawQuestion: JSONValue = .object([
            "tag": .string(BasicChoiceQuestionKind.chooseOne.rawValue),
            "choices": .array(choices.map(\.rawValue)),
        ])
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: playerID,
                questionVersion: 1,
                rawQuestion: rawQuestion,
                questionPresentation: semanticPresentation?.presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: .supported(BasicChoiceQuestion(
                kind: .chooseOne,
                choices: choices,
                story: nil,
                rawValue: rawQuestion
            )),
            semanticPresentation: semanticPresentation,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private func ability(cardCode: String) -> BasicChoiceAbility {
        BasicChoiceAbility(
            investigatorID: investigatorID,
            cardCode: BoardTestFixtures.cardCode(cardCode),
            rawAbility: .null,
            windows: [],
            before: [],
            messages: []
        )
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
