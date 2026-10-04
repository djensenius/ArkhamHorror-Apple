@testable import ArkhamHorrorShared
import Testing

@MainActor
@Suite("Board linked enemy action catalog titles")
struct BoardLinkedEnemyActionCatalogTests {
    private struct EnemyLocationIDs {
        let location: LocationID
        let firstEnemy: EnemyID
        let secondEnemy: EnemyID
    }

    @Test("Location enemy action menu titles use catalog names when payload omits names")
    func locationEnemyActionMenuTitlesUseCatalogNamesWhenPayloadOmitsNames() {
        let ids = enemyLocationIDs()
        let projection = locationEnemyProjection(ids: ids)
        let prompt = enemyPrompt(choices: duplicateEnemyChoices(ids))
        let actionsFocus = BoardFocusID.locationEnemyActions(ids.location)
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            cardCatalog: ghoulCatalog
        )

        #expect(controller.handle(focusID: actionsFocus, .command(.primaryAction)))
        #expect(controller.linkedChoiceMenuRequest == BoardLinkedChoiceMenuRequest(
            focusID: actionsFocus,
            choices: expectedDuplicateEnemyMenuChoices()
        ))
    }

    @Test("Open location enemy action menu refreshes titles when catalog arrives")
    func openLocationEnemyActionMenuRefreshesTitlesWhenCatalogArrives() throws {
        let ids = enemyLocationIDs()
        let projection = locationEnemyProjection(ids: ids)
        let prompt = enemyPrompt(choices: duplicateEnemyChoices(ids))
        let actionsFocus = BoardFocusID.locationEnemyActions(ids.location)
        let controller = BoardCommandController(projection: projection, prompt: prompt)

        #expect(controller.handle(focusID: actionsFocus, .command(.primaryAction)))
        let fallbackRequest = try #require(controller.linkedChoiceMenuRequest)
        #expect(fallbackRequest.choices == expectedFallbackDuplicateEnemyMenuChoices())
        #expect(controller.handle(.command(.focusMove(.down))))
        #expect(controller.coordinator.currentFocus == BoardFocusID.linkedChoiceMenuChoice(8))

        controller.updateCardCatalog(ghoulCatalog)

        let refreshedRequest = try #require(controller.linkedChoiceMenuRequest)
        #expect(refreshedRequest.focusID == actionsFocus)
        #expect(refreshedRequest.choices.map(\.choiceIndex) == [7, 8, 20, 21])
        #expect(refreshedRequest.choices == expectedDuplicateEnemyMenuChoices())
        #expect(controller.coordinator.currentFocus == BoardFocusID.linkedChoiceMenuChoice(8))
    }

    @Test("Duplicate enemy menu suffixes localize in German")
    func duplicateEnemyMenuSuffixesLocalizeInGerman() {
        let ids = enemyLocationIDs()
        let enemies = locationEnemyProjection(ids: ids).enemiesByLocationID[ids.location] ?? []
        let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]] = [
            .enemy(ids.firstEnemy): [
                BoardLinkedChoice(choiceIndex: 7, title: "Fight", isActionable: true),
            ],
            .enemy(ids.secondEnemy): [
                BoardLinkedChoice(choiceIndex: 20, title: "Fight", isActionable: true),
            ],
        ]

        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("de") {
            let choices = BoardEnemyCompactFormatting.titledLinkedChoicesByEnemy(
                enemies: enemies,
                choiceLinks: choiceLinks,
                cardCatalog: ghoulCatalog
            )

            #expect(choices.map(\.title) == [
                "Ghoul Minion: F 2  H 2  E 3 (Gegner 1): Fight",
                "Ghoul Minion: F 2  H 2  E 3 (Gegner 2): Fight",
            ])
        }
    }

    private var ghoulCatalog: CardCatalogSnapshot {
        CardCatalogSnapshot(namesByCode: [
            BoardTestFixtures.cardCode("c01159"): CardName(
                title: "Ghoul Minion",
                subtitle: nil
            ),
        ])
    }

    private func enemyLocationIDs() -> EnemyLocationIDs {
        EnemyLocationIDs(
            location: BoardTestFixtures.locationID("000000000446"),
            firstEnemy: BoardTestFixtures.enemyID("000000000447"),
            secondEnemy: BoardTestFixtures.enemyID("000000000448")
        )
    }

    private func locationEnemyProjection(ids: EnemyLocationIDs) -> BoardProjection {
        BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: [(
                ids.location,
                .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: ids.location,
                    enemies: [ids.firstEnemy, ids.secondEnemy]
                ))
            )],
            enemyValues: [
                ids.firstEnemy: .object(enemyValueWithoutInlineName()),
                ids.secondEnemy: .object(enemyValueWithoutInlineName()),
            ]
        ))
    }

    private func enemyValueWithoutInlineName(
        cardCode: String = "c01159",
        fight: Int = 2,
        health: Int = 2,
        evade: Int = 3
    ) -> [String: JSONValue] {
        [
            "cardCode": .string(cardCode),
            "fight": .number(.integer(Int64(fight))),
            "health": .number(.integer(Int64(health))),
            "evade": .number(.integer(Int64(evade))),
        ]
    }

    private func enemyPrompt(choices: [BasicChoice]) -> BasicChoicePromptPresentation {
        let rawQuestion: JSONValue = .object([
            "tag": .string(BasicChoiceQuestionKind.chooseOne.rawValue),
            "choices": .array(choices.map(\.rawValue)),
        ])
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: 1,
                rawQuestion: rawQuestion,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: .supported(BasicChoiceQuestion(
                kind: .chooseOne,
                choices: choices,
                story: nil,
                rawValue: rawQuestion
            )),
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private func duplicateEnemyChoices(_ ids: EnemyLocationIDs) -> [BasicChoice] {
        [
            fightChoice(index: 7, enemyID: ids.firstEnemy),
            evadeChoice(index: 8, enemyID: ids.firstEnemy),
            fightChoice(index: 20, enemyID: ids.secondEnemy),
            evadeChoice(index: 21, enemyID: ids.secondEnemy),
        ]
    }

    private func fightChoice(index: Int, enemyID: EnemyID) -> BasicChoice {
        BasicChoice(
            index: index,
            rawValue: .string("fight-\(index)"),
            content: .fight(enemyAbility(), enemyID: enemyID)
        )
    }

    private func evadeChoice(index: Int, enemyID: EnemyID) -> BasicChoice {
        BasicChoice(
            index: index,
            rawValue: .string("evade-\(index)"),
            content: .evade(enemyAbility(), enemyID: enemyID)
        )
    }

    private func enemyAbility() -> BasicChoiceAbility {
        BasicChoiceAbility(
            investigatorID: BoardTestFixtures.investigatorID("c01001"),
            cardCode: BoardTestFixtures.cardCode("c01160"),
            rawAbility: .null,
            windows: [],
            before: [],
            messages: []
        )
    }

    private func expectedFallbackDuplicateEnemyMenuChoices() -> [BoardLinkedChoice] {
        [
            BoardLinkedChoice(
                choiceIndex: 7,
                title: "Card c01159: F 2  H 2  E 3 (enemy 1): Fight",
                isActionable: true
            ),
            BoardLinkedChoice(
                choiceIndex: 8,
                title: "Card c01159: F 2  H 2  E 3 (enemy 1): Evade",
                isActionable: true
            ),
            BoardLinkedChoice(
                choiceIndex: 20,
                title: "Card c01159: F 2  H 2  E 3 (enemy 2): Fight",
                isActionable: true
            ),
            BoardLinkedChoice(
                choiceIndex: 21,
                title: "Card c01159: F 2  H 2  E 3 (enemy 2): Evade",
                isActionable: true
            ),
        ]
    }

    private func expectedDuplicateEnemyMenuChoices() -> [BoardLinkedChoice] {
        [
            BoardLinkedChoice(
                choiceIndex: 7,
                title: "Ghoul Minion: F 2  H 2  E 3 (enemy 1): Fight",
                isActionable: true
            ),
            BoardLinkedChoice(
                choiceIndex: 8,
                title: "Ghoul Minion: F 2  H 2  E 3 (enemy 1): Evade",
                isActionable: true
            ),
            BoardLinkedChoice(
                choiceIndex: 20,
                title: "Ghoul Minion: F 2  H 2  E 3 (enemy 2): Fight",
                isActionable: true
            ),
            BoardLinkedChoice(
                choiceIndex: 21,
                title: "Ghoul Minion: F 2  H 2  E 3 (enemy 2): Evade",
                isActionable: true
            ),
        ]
    }
}
