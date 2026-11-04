@testable import ArkhamHorrorShared
import Foundation
import Testing

/// TASK-1.22.12 stage 3: a `[^N]` footnote in an amount prompt label, a Scarlet Keys travel
/// label or the deck-picker heading renders as a marker and VoiceOver reads "footnote N".
@Suite("Amount, Scarlet Keys travel and deck heading footnotes")
struct AmountTravelDeckFootnoteTests {
    private let projection = BoardProjectionBuilder.makeProjection(
        from: BoardTestFixtures.snapshot()
    )
    private static let multiNodes: [StoryNode] = [
        .text("A"), .footnoteMarker("1"), .text(" and B"), .footnoteMarker("22"),
    ]

    // MARK: Amount prompt

    @Test("Raw amount legend and row labels render markers and speak footnotes")
    func rawAmountLabelsRenderMarkers() throws {
        let amountPrompt = try amountPrompt(
            legend: "Assign 1927[^5]", rowLabel: "A[^1] and B[^22]"
        )
        let row = try #require(amountPrompt.rows.first)

        #expect(amountPrompt.legend == "Assign 1927[^5]")
        #expect(amountPrompt.legendFootnote == BasicChoiceFootnotedText(
            nodes: [.text("Assign 1927"), .footnoteMarker("5")],
            accessibilityLabel: "Assign 1927 footnote 5"
        ))
        #expect(row.title == "A[^1] and B[^22]")
        #expect(row.titleFootnote?.nodes == Self.multiNodes)
        #expect(row.spokenTitle == "A footnote 1 and B footnote 22")
    }

    @Test("A catalog amount row uses its resolved nodes; a marker-only row speaks the marker")
    func catalogAndMarkerOnlyAmountRows() throws {
        let nodes: [StoryNode] = [.text("Clues "), .footnoteMarker("3")]
        let catalog = try amountPrompt(
            legend: "Assign",
            rowLabel: "$clues",
            resolutions: [
                "amountChoice.row": .resolved(.init(title: "Clues 3", inlineNodes: nodes)),
            ]
        )
        let catalogRow = try #require(catalog.rows.first)
        #expect(catalogRow.title == "Clues 3")
        #expect(catalogRow.titleFootnote?.nodes == nodes)
        #expect(catalogRow.spokenTitle == "Clues  footnote 3")

        let markerOnly = try #require(amountPrompt(legend: "Assign", rowLabel: "[^5]").rows.first)
        #expect(markerOnly.title == "[^5]")
        #expect(markerOnly.titleFootnote?.nodes == [.footnoteMarker("5")])
        #expect(markerOnly.spokenTitle == " footnote 5")
    }

    @Test("Amount labels without footnotes are unchanged")
    func amountLabelsWithoutFootnotesAreUnchanged() throws {
        let amountPrompt = try amountPrompt(legend: "Assign clues", rowLabel: "Clues")
        let row = try #require(amountPrompt.rows.first)

        #expect(amountPrompt.legend == "Assign clues")
        #expect(amountPrompt.legendFootnote == nil)
        #expect(row.title == "Clues")
        #expect(row.titleFootnote == nil)
        #expect(row.spokenTitle == "Clues")
    }

    // MARK: Scarlet Keys travel

    @Test("Footnoted Scarlet Keys travel labels carry markers and spoken titles")
    func footnotedTravelLabels() throws {
        let travel = try travelPrompt(resolutions: [
            "scarletKeysTravel.location.Alexandria.name": .resolved(.init(
                title: "Alexandria 1", inlineNodes: [.text("Alexandria "), .footnoteMarker("1")]
            )),
            "scarletKeysTravel.action.travel": .resolved(.init(
                title: "A1 and B22", inlineNodes: Self.multiNodes
            )),
            "scarletKeysTravel.travelTime": .resolved(.init(
                title: "4", inlineNodes: [.footnoteMarker("4")]
            )),
            "scarletKeys.locationLocked": .resolved(.init(
                title: "Locked6", inlineNodes: [.text("Locked"), .footnoteMarker("6")]
            )),
            "scarletKeys.youAreCurrentlyHere": .resolved(.init(
                title: "Here7", inlineNodes: [.text("Here"), .footnoteMarker("7")],
                accessibilityTitle: "Here footnote 7"
            )),
        ])
        let alexandria = try #require(travel.locations.first { $0.id == "Alexandria" })
        let action = try #require(alexandria.actions.first { $0.kind == .travel })

        #expect(alexandria.title == "Alexandria 1")
        #expect(alexandria.titleFootnote == BasicChoiceFootnotedText(
            nodes: [.text("Alexandria "), .footnoteMarker("1")],
            accessibilityLabel: "Alexandria  footnote 1"
        ))
        #expect(action.title == "A1 and B22")
        #expect(action.titleFootnote?.nodes == Self.multiNodes)
        #expect(action.spokenTitle == "A footnote 1 and B footnote 22")
        #expect(action.spokenLocationTitle == "Alexandria  footnote 1")
        let spokenTitle = try #require(action.spokenTitle)
        #expect(ScarletKeysTravelPromptView.actionAccessibilityLabel(
            title: spokenTitle, locationTitle: action.spokenLocationTitle
        ) == "A footnote 1 and B footnote 22: Alexandria  footnote 1")
        #expect(travel.travelTimeLabelFootnote == BasicChoiceFootnotedText(
            nodes: [.footnoteMarker("4")], accessibilityLabel: " footnote 4"
        ))
        let locked = try #require(travel.locations.first { $0.isLocked })
        #expect(locked.lockedTitle == "Locked6")
        #expect(locked.lockedTitleFootnote?.accessibilityLabel == "Locked footnote 6")
        #expect(travel.locations.filter { !$0.isLocked }.allSatisfy {
            $0.lockedTitleFootnote == nil
        })
        #expect(travel.currentLocationTitleFootnote?.accessibilityLabel == "Here footnote 7")
    }

    @Test("Scarlet Keys travel labels without footnotes are unchanged")
    func travelLabelsWithoutFootnotesAreUnchanged() throws {
        let travel = try travelPrompt(resolutions: [
            "scarletKeysTravel.location.Alexandria.name": .resolved("Alexandria"),
            "scarletKeysTravel.action.travel": .resolved(.init(
                title: "Travel action", inlineNodes: [.text("Travel "), .icon("action")]
            )),
            "scarletKeys.locationLocked": .resolved("Location locked"),
        ])
        let alexandria = try #require(travel.locations.first { $0.id == "Alexandria" })
        let action = try #require(alexandria.actions.first { $0.kind == .travel })

        #expect(alexandria.titleFootnote == nil)
        #expect(action.title == "Travel action")
        #expect(action.titleFootnote == nil)
        #expect(action.locationTitleFootnote == nil)
        #expect(action.spokenTitle == "Travel action")
        #expect(action.spokenLocationTitle == "Alexandria")
        #expect(travel.locations.allSatisfy { $0.lockedTitleFootnote == nil })
        #expect(travel.currentLocationTitleFootnote == nil)
        #expect(travel.travelTimeLabelFootnote == nil)
    }

    // MARK: Deck-picker heading

    @Test("A footnoted deck-picker heading renders markers and speaks each footnote")
    func footnotedDeckPickerHeading() throws {
        let multi = try deckPrompt(questionLabel: "A[^1] and B[^22]")
        #expect(multi.liveChooseDeckPickerHeading == "A[^1] and B[^22]")
        #expect(multi.liveChooseDeckPickerHeadingFootnote == BasicChoiceFootnotedText(
            nodes: Self.multiNodes, accessibilityLabel: "A footnote 1 and B footnote 22"
        ))

        let markerOnly = try deckPrompt(questionLabel: "[^5]")
        #expect(markerOnly.liveChooseDeckPickerHeadingFootnote == BasicChoiceFootnotedText(
            nodes: [.footnoteMarker("5")], accessibilityLabel: " footnote 5"
        ))
    }

    @Test("Deck-picker headings without footnotes are unchanged")
    func deckPickerHeadingWithoutFootnoteIsUnchanged() throws {
        let prompt = try deckPrompt(questionLabel: "Choose Dream Side")
        #expect(prompt.liveChooseDeckPickerHeading == "Choose Dream Side")
        #expect(prompt.liveChooseDeckPickerHeadingFootnote == nil)
    }

    // MARK: Fixtures

    private func amountPrompt(
        legend: String,
        rowLabel: String,
        resolutions: [String: BasicChoiceLabelResolution] = [:]
    ) throws -> BasicChoiceAmountPrompt {
        let rawQuestion = JSONValue.object([
            "tag": .string("ChooseAmounts"),
            "label": .string(legend),
            "amountTargetValue": .object([
                "tag": .string("MaxAmountTarget"), "contents": .number(.integer(3)),
            ]),
            "amountChoices": .array([.object([
                "choiceId": .string("row"), "label": .string(rowLabel),
                "minBound": .number(.integer(0)), "maxBound": .number(.integer(3)),
            ])]),
            "target": .object(["tag": .string("LocationTarget"), "contents": .string("loc")]),
        ])
        let presentation = QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: 914,
            questionKind: .chooseAmounts,
            choiceCount: 0,
            choices: [],
            answer: .amounts,
            label: .init(kind: .embeddedI18n, text: legend),
            target: .max(3),
            amountChoices: [.init(choiceID: "row", label: rowLabel, minBound: 0, maxBound: 3)]
        )
        let prompt = try basicPrompt(
            rawQuestion: rawQuestion,
            presentation: presentation,
            resolutions: resolutions
        )
        return try #require(prompt.amountPrompt(in: projection))
    }

    private func travelPrompt(
        resolutions: [String: BasicChoiceLabelResolution]
    ) throws -> ScarletKeysTravelPromptPresentation {
        let url = try #require(Bundle.module.url(
            forResource: "roland-c09501-q145-embark-world-map",
            withExtension: "json",
            subdirectory: "Fixtures/LiveScarletKeysPlaythrough"
        ))
        let fixture = try ContractJSON.decode(TravelFixture.self, from: Data(contentsOf: url))
        return try #require(ScarletKeysTravelPromptPresentation.make(
            rawQuestion: fixture.rawQuestion,
            presentation: fixture.questionPresentation,
            labelResolutions: resolutions
        ))
    }

    private func deckPrompt(questionLabel: String) throws -> BasicChoicePromptPresentation {
        let rawQuestion = JSONValue.object([
            "card": .null,
            "label": .string(questionLabel),
            "question": .object(["tag": .string("ChooseDeck")]),
            "tag": .string("QuestionLabel"),
        ])
        let presentation = QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: 914,
            questionKind: .chooseDeck,
            choiceCount: 0,
            choices: [],
            answer: .deck(tags: ["DeckAnswer"]),
            questionLabel: .init(kind: .embeddedI18n, text: questionLabel)
        )
        return try basicPrompt(rawQuestion: rawQuestion, presentation: presentation)
    }

    private func basicPrompt(
        rawQuestion: JSONValue,
        presentation: QuestionPresentation,
        resolutions: [String: BasicChoiceLabelResolution] = [:]
    ) throws -> BasicChoicePromptPresentation {
        let binding = try presentation.bind(to: rawQuestion, expectedQuestionVersion: 914)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 914,
                rawQuestion: rawQuestion,
                questionPresentation: presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: BasicChoiceParser.parseQuestion(rawQuestion),
            semanticPresentation: binding,
            semanticLocaleIdentifier: "en",
            promptLabelResolutions: resolutions,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }
}

private struct TravelFixture: Decodable {
    let rawQuestion: JSONValue
    let questionPresentation: QuestionPresentation
}
