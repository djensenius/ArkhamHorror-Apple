@testable import ArkhamHorrorShared
import Testing

/// TASK-1.22.12 stage 2: a `[^N]` footnote in the question-label header, a choice subtitle
/// or an info choice title renders as a marker and VoiceOver reads "footnote N".
@Suite("Prompt header, subtitle and info title footnotes")
struct PromptFootnoteSurfaceTests {
    private let projection = BoardProjectionBuilder.makeProjection(
        from: BoardTestFixtures.snapshot()
    )

    @Test("A raw question-label header renders its footnote as a marker")
    func rawQuestionLabelHeaderRendersMarker() throws {
        let prompt = try prompt(questionLabel: "Read 1927[^5]")

        #expect(prompt.headerTitle(in: projection) == "Read 1927[^5]")
        #expect(prompt.promptQuestionLabelFootnote == BasicChoiceFootnotedText(
            nodes: [.text("Read 1927"), .footnoteMarker("5")],
            accessibilityLabel: "Read 1927 footnote 5"
        ))
    }

    @Test("A catalog question-label header uses its resolved nodes and spoken title")
    func catalogQuestionLabelHeaderUsesResolvedNodes() throws {
        let nodes: [StoryNode] = [.text("See note "), .footnoteMarker("12")]
        let prompt = try prompt(
            questionLabel: "$label.note",
            promptLabelResolutions: ["questionLabel": .resolved(.init(
                title: "See note 12", inlineNodes: nodes,
                accessibilityTitle: "See note  footnote 12"
            ))]
        )

        #expect(prompt.headerTitle(in: projection) == "See note 12")
        #expect(prompt.promptQuestionLabelFootnote == BasicChoiceFootnotedText(
            nodes: nodes, accessibilityLabel: "See note  footnote 12"
        ))
    }

    @Test("Headers without footnotes are unchanged")
    func headersWithoutFootnotesAreUnchanged() throws {
        let raw = try prompt(questionLabel: "Choose a path")
        #expect(raw.headerTitle(in: projection) == "Choose a path")
        #expect(raw.promptQuestionLabelFootnote == nil)

        let catalog = try prompt(
            questionLabel: "$label.path",
            promptLabelResolutions: ["questionLabel": .resolved(.init(
                title: "Spend action", inlineNodes: [.text("Spend "), .icon("action")]
            ))]
        )
        #expect(catalog.headerTitle(in: projection) == "Spend action")
        #expect(catalog.promptQuestionLabelFootnote == nil)

        let generic = try prompt(questionLabel: nil)
        #expect(generic.headerTitle(in: projection) == "Choose an action")
        #expect(generic.promptQuestionLabelFootnote == nil)
    }

    @Test("A choice subtitle renders its footnote as a marker and speaks it")
    func choiceSubtitleRendersMarker() throws {
        let resolved = try resolvedLabel(.init(
            sourceIndex: 0, kind: .localizedLabel,
            label: .init(kind: .embeddedI18n, text: "Wrote"),
            tooltip: "See the note[^2]"
        ))

        #expect(resolved.subtitle == "See the note2")
        #expect(resolved.subtitleNodes == [.text("See the note"), .footnoteMarker("2")])
        #expect(resolved.accessibilityLabel == "Wrote, See the note footnote 2")
    }

    @Test("Subtitles without footnotes keep no nodes")
    func subtitlesWithoutFootnotesAreUnchanged() throws {
        let resolved = try resolvedLabel(.init(
            sourceIndex: 0, kind: .localizedLabel,
            label: .init(kind: .embeddedI18n, text: "Wrote"),
            tooltip: "See {skull}"
        ))

        #expect(resolved.subtitle == "See Skull")
        #expect(resolved.subtitleNodes == nil)
        #expect(resolved.accessibilityLabel == "Wrote, See Skull")
    }

    @Test("A raw info title renders its footnote as a marker and speaks it")
    func rawInfoTitleRendersMarker() throws {
        let resolved = try resolvedLabel(infoChoice(title: "Note 1927[^5]"))

        #expect(resolved.title == "Note 19275")
        #expect(resolved.titleNodes == [.text("Note 1927"), .footnoteMarker("5")])
        #expect(resolved.accessibilityLabel == "Note 1927 footnote 5")
    }

    @Test("A resolved flavor info title uses its footnoted nodes and spoken form")
    func resolvedInfoTitleUsesStoryNodes() throws {
        let nodes: [StoryNode] = [.text("Diary 1927"), .footnoteMarker("3")]
        let resolved = try resolvedLabel(
            infoChoice(title: "$story.diary"),
            choiceFlavorResolutions: [0: .resolved(ResolvedStory(
                title: "Diary 19273", titleNodes: nodes, body: []
            ))]
        )

        #expect(resolved.title == "Diary 19273")
        #expect(resolved.titleNodes == nodes)
        #expect(resolved.accessibilityLabel == "Diary 1927 footnote 3")
    }

    @Test("Info titles without footnotes are unchanged")
    func infoTitlesWithoutFootnotesAreUnchanged() throws {
        let raw = try resolvedLabel(infoChoice(title: "Plain {skull} note"))
        #expect(raw.title == "Plain Skull note")
        #expect(raw.titleNodes == nil)
        #expect(raw.accessibilityLabel == "Plain Skull note")

        let story = try resolvedLabel(
            infoChoice(title: "$story.plain"),
            choiceFlavorResolutions: [0: .resolved(ResolvedStory(title: "Plain diary", body: []))]
        )
        #expect(story.title == "Plain diary")
        #expect(story.titleNodes == nil)
        #expect(story.accessibilityLabel == "Plain diary")
    }

    private func infoChoice(title: String) -> QuestionPresentation.Choice {
        .init(
            sourceIndex: 0, kind: .info,
            flavorText: QuestionPresentation.FlavorText(title: title, body: [])
        )
    }

    private func resolvedLabel(
        _ choice: QuestionPresentation.Choice,
        choiceFlavorResolutions: [Int: StoryResolution] = [:]
    ) throws -> BasicChoiceResolvedChoiceLabel {
        let prompt = try prompt(
            choices: [choice], choiceFlavorResolutions: choiceFlavorResolutions
        )
        let basicChoice = try #require(prompt.choices.first)
        return prompt.resolvedChoiceLabel(for: basicChoice, in: projection)
    }

    private func prompt(
        questionLabel: String? = nil,
        choices: [QuestionPresentation.Choice] = [
            .init(
                sourceIndex: 0,
                kind: .localizedLabel,
                label: .init(kind: .embeddedI18n, text: "Go")
            ),
        ],
        choiceFlavorResolutions: [Int: StoryResolution] = [:],
        promptLabelResolutions: [String: BasicChoiceLabelResolution] = [:]
    ) throws -> BasicChoicePromptPresentation {
        let presentation = QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: 913,
            questionKind: .chooseOne,
            choiceCount: choices.count,
            choices: choices,
            questionLabel: questionLabel.map { .init(kind: .embeddedI18n, text: $0) }
        )
        let rawQuestion = GenericSingleChoiceRawQuestionFixtures.directQuestion(
            tag: "ChooseOne", count: choices.count
        )
        let binding = try presentation.bind(to: rawQuestion, expectedQuestionVersion: 913)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 913,
                rawQuestion: rawQuestion,
                questionPresentation: presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: BasicChoiceParser.parseQuestion(rawQuestion),
            semanticPresentation: binding,
            semanticLocaleIdentifier: "en",
            choiceFlavorResolutions: choiceFlavorResolutions,
            promptLabelResolutions: promptLabelResolutions,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }
}
