@testable import ArkhamHorrorShared
import Testing

/// TASK-1.22.12: a `[^N]` footnote in a board-linked choice title shows as a marker or
/// superscript digits instead of run-together digits, and VoiceOver reads "footnote N".
@Suite("Board linked choice footnotes")
struct BoardLinkedChoiceFootnoteTests {
    private let enemyID = BoardTestFixtures.enemyID("000000000912")

    @Test("The linker carries display nodes and a spoken title for a footnoted label")
    func linkerCarriesNodesAndSpokenTitleForFootnote() throws {
        let links = try links(labels: ["Wrote 1927[^5]", "Fight"])
        let choices = try #require(links[.enemy(enemyID)])

        #expect(choices.map(\.choiceIndex) == [0, 1])
        #expect(choices[0].title == "Wrote 19275")
        #expect(choices[0].displayNodes == [.text("Wrote 1927"), .footnoteMarker("5")])
        #expect(choices[0].accessibilityTitle == "Wrote 1927 footnote 5")
        #expect(choices[0].spokenTitle == "Wrote 1927 footnote 5")
        #expect(choices[0].menuTitle == "Wrote 1927⁵")
    }

    @Test("Labels without footnotes keep nil fields and identical strings")
    func labelsWithoutFootnotesAreUnchanged() throws {
        let links = try links(labels: ["Fight", "Gain {action}"])
        let choices = try #require(links[.enemy(enemyID)])

        #expect(choices.map(\.title) == ["Fight", "Gain Action"])
        #expect(choices.map(\.displayNodes) == [nil, nil])
        #expect(choices.map(\.accessibilityTitle) == [nil, nil])
        #expect(choices.map(\.spokenTitle) == ["Fight", "Gain Action"])
        #expect(choices.map(\.menuTitle) == ["Fight", "Gain Action"])
        #expect(choices[0] == BoardLinkedChoice(
            choiceIndex: 0, title: "Fight", isActionable: choices[0].isActionable
        ))
    }

    @Test("Chip hints and the board modal row show a marker and speak \"footnote N\"")
    func chipAndModalRowSpeakFootnote() throws {
        let choice = try #require(links(labels: ["See the note[^12]"])[.enemy(enemyID)]?.first)

        let hint = BoardLinkedEnemyActionsControl.accessibilityHint(for: .submit(choice))
        #expect(hint == "Activates See the note footnote 12")
        #expect(BoardEnemyTileChipView.accessibilityHint(for: .submit(choice)) == hint)
        #expect(BoardEnemyCompactChipView.accessibilityHint(for: .submit(choice)) == hint)
        let menuHint = "Choose which prompt action to take."
        #expect(BoardEnemyTileChipView.accessibilityHint(for: .menu([choice])) == menuHint)
        #expect(BoardEnemyCompactChipView.accessibilityHint(for: .menu([choice])) == menuHint)

        let row = BoardLinkedChoiceMenuChoicePresentation(choice: choice, focusedID: nil)
        #expect(row.title == "See the note12")
        #expect(row.titleNodes == [.text("See the note"), .footnoteMarker("12")])
        #expect(row.accessibilityLabel == "See the note footnote 12")
    }

    @Test("Native menu rows use superscript digits with the spoken accessibility title")
    func nativeMenuRowsUseSuperscriptAndSpokenTitle() throws {
        let choice = try #require(links(labels: ["See the note[^12]"])[.enemy(enemyID)]?.first)
        let row = BoardLinkedChoiceMenuButton(choice: choice) {}
        #expect(row.title == "See the note¹²")
        #expect(row.accessibilityTitle == "See the note footnote 12")

        let plain = BoardLinkedChoiceMenuButton(
            choice: BoardLinkedChoice(choiceIndex: 1, title: "Fight", isActionable: true)
        ) {}
        #expect(plain.title == "Fight")
        #expect(plain.accessibilityTitle == "Fight")
    }

    @Test("Enemy-prefixed modal choices keep the marker and the spoken title")
    func enemyPrefixedChoicesKeepFootnote() {
        let choice = BoardLinkedChoice(
            choiceIndex: 3,
            title: "Note2",
            isActionable: true,
            displayNodes: [.text("Note"), .footnoteMarker("2")],
            accessibilityTitle: "Note footnote 2"
        )
        let enemy = BoardEnemyNode(
            id: enemyID, cardCode: nil, displayName: "Ghoul", fight: nil, health: nil,
            evade: nil, damage: nil, horror: nil, attackDamage: nil, attackHorror: nil,
            exhausted: false, engagedInvestigatorID: nil, locationID: nil, tokenCounts: []
        )
        let titled = BoardEnemyCompactFormatting.titledLinkedChoicesByEnemy(
            enemies: [enemy], choiceLinks: [.enemy(enemyID): [choice]]
        )
        #expect(titled.map(\.title) == ["Ghoul: Enemy: Note2"])
        #expect(titled.map(\.menuTitle) == ["Ghoul: Enemy: Note²"])
        #expect(titled.map(\.spokenTitle) == ["Ghoul: Enemy: Note footnote 2"])
    }

    @Test("Superscript helper raises multi-digit and multiple footnotes")
    func superscriptHelperRaisesEveryFootnote() {
        #expect(StoryFootnoteSuperscript.superscript("1234567890") == "¹²³⁴⁵⁶⁷⁸⁹⁰")
        #expect(StoryFootnoteSuperscript.title(for: [
            .text("Read 1927"), .footnoteMarker("12"), .text(" and "),
            .emphasis(.bold, [.text("this"), .footnoteMarker("3")]),
        ]) == "Read 1927¹² and this³")
        #expect(StoryFootnoteSuperscript.title(for: [.text("No note"), .icon("action")]) == nil)
    }

    private func links(
        labels: [String]
    ) throws -> [BoardPromptElementID: [BoardLinkedChoice]] {
        let choices = labels.enumerated().map { index, text in
            QuestionPresentation.Choice(
                sourceIndex: index,
                kind: .localizedLabel,
                entity: .init(kind: .enemy, id: enemyID.codingKey.stringValue),
                label: .init(kind: .embeddedI18n, text: text)
            )
        }
        let presentation = QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: 912,
            questionKind: .chooseOne,
            choiceCount: choices.count,
            choices: choices
        )
        let rawQuestion = GenericSingleChoiceRawQuestionFixtures.directQuestion(
            tag: "ChooseOne", count: choices.count
        )
        let binding = try presentation.bind(to: rawQuestion, expectedQuestionVersion: 912)
        let prompt = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 912,
                rawQuestion: rawQuestion,
                questionPresentation: presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: BasicChoiceParser.parseQuestion(rawQuestion),
            semanticPresentation: binding,
            semanticLocaleIdentifier: "en",
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        return BoardPromptChoiceLinker.links(prompt: prompt, projection: projection)
    }
}
