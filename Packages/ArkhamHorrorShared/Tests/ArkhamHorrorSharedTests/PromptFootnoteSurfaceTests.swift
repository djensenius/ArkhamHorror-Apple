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

    @Test("A resolved info title whose nodes carry no footnote keeps no nodes")
    func resolvedInfoTitleNodesWithoutFootnoteAreIgnored() throws {
        let story = try resolvedLabel(
            infoChoice(title: "$story.plain"),
            choiceFlavorResolutions: [0: .resolved(ResolvedStory(
                title: "Plain diary", titleNodes: [.text("Plain diary")], body: []
            ))]
        )
        #expect(story.title == "Plain diary")
        #expect(story.titleNodes == nil)
        #expect(story.accessibilityLabel == "Plain diary")
    }

    @Test("A header's nodes keep its text; a catalog header's plain text matches headerTitle")
    func headerNodesMatchHeaderTitle() throws {
        let catalogNodes: [StoryNode] = [.text("See note "), .footnoteMarker("12")]
        let catalog = try prompt(
            questionLabel: "$label.note",
            promptLabelResolutions: ["questionLabel": .resolved(.init(
                title: "See note 12", inlineNodes: catalogNodes
            ))]
        )
        let catalogFootnote = try #require(catalog.promptQuestionLabelFootnote)
        #expect(catalogFootnote.nodes.map(\.plainText).joined()
            == catalog.headerTitle(in: projection))
        #expect(catalogFootnote.accessibilityLabel == "See note  footnote 12")

        // A raw header keeps the literal `[^N]` as its String fallback (as the web shows);
        // its nodes carry the same text with the reference split out as a marker.
        let raw = try prompt(questionLabel: "Read 1927[^5]")
        let rawFootnote = try #require(raw.promptQuestionLabelFootnote)
        #expect(raw.headerTitle(in: projection) == "Read 1927[^5]")
        #expect(rawFootnote.nodes.map(\.plainText).joined() == "Read 19275")
    }

    @Test("A header with several footnotes renders and speaks each marker")
    func headerWithSeveralFootnotes() throws {
        let prompt = try prompt(questionLabel: "A[^1] and B[^22]")

        #expect(prompt.promptQuestionLabelFootnote == BasicChoiceFootnotedText(
            nodes: [.text("A"), .footnoteMarker("1"), .text(" and B"), .footnoteMarker("22")],
            accessibilityLabel: "A footnote 1 and B footnote 22"
        ))
    }

    @Test("A subtitle and an info title with several footnotes render each marker")
    func subtitleAndInfoTitleWithSeveralFootnotes() throws {
        let markers: [StoryNode] = [
            .text("A"), .footnoteMarker("1"), .text(" and B"), .footnoteMarker("22"),
        ]
        let subtitle = try resolvedLabel(.init(
            sourceIndex: 0, kind: .localizedLabel,
            label: .init(kind: .embeddedI18n, text: "Wrote"),
            tooltip: "A[^1] and B[^22]"
        ))
        #expect(subtitle.subtitle == "A1 and B22")
        #expect(subtitle.subtitleNodes == markers)
        #expect(subtitle.accessibilityLabel == "Wrote, A footnote 1 and B footnote 22")

        let info = try resolvedLabel(infoChoice(title: "A[^1] and B[^22]"))
        #expect(info.title == "A1 and B22")
        #expect(info.titleNodes == markers)
        #expect(info.accessibilityLabel == "A footnote 1 and B footnote 22")
    }

    @Test("A marker-only label renders just the marker and speaks \"footnote N\"")
    func markerOnlyLabels() throws {
        // Spoken labels are trimmed, so a marker-only label has no leading space.
        let header = try prompt(questionLabel: "[^5]")
        #expect(header.headerTitle(in: projection) == "[^5]")
        #expect(header.promptQuestionLabelFootnote == BasicChoiceFootnotedText(
            nodes: [.footnoteMarker("5")], accessibilityLabel: "footnote 5"
        ))

        // A choice's spoken label is trimmed, so the info title has no leading space.
        let info = try resolvedLabel(infoChoice(title: "[^5]"))
        #expect(info.title == "5")
        #expect(info.titleNodes == [.footnoteMarker("5")])
        #expect(info.accessibilityLabel == "footnote 5")
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
