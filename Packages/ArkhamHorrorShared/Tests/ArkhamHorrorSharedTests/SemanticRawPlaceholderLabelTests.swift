@testable import ArkhamHorrorShared
import Foundation
import Testing

/// TASK-1.22.14: a catalog `$` label whose text variable supplies a raw `{icon}` or escape
/// renders on a semantic prompt exactly as the same label does on a legacy prompt.
@Suite("Semantic raw-placeholder catalog labels")
struct SemanticRawPlaceholderLabelTests {
    private struct Rendered: Equatable {
        let title: String
        let titleNodes: [StoryNode]?
        let accessibilityLabel: String
    }

    @MainActor
    private static func semanticLabel(
        _ wireLabel: String
    ) async throws -> (BasicChoiceLabelResolution?, Rendered) {
        let fixture = try LiveNotZTypedLabelVariableTests.fixture()
            .replacingChoiceLabel(at: 0, with: wireLabel)
        let labelModel = try await LiveNotZTypedLabelVariableTests.productionLabelModel()
        let prompt = try LiveNotZTypedLabelVariableTests.prompt(
            for: fixture, labelModel: labelModel
        )
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let choice = try #require(prompt.choices.first { $0.index == 0 })
        let resolved = prompt.resolvedChoiceLabel(for: choice, in: projection)
        #expect(prompt.isChoiceActionable(choice, in: projection))
        return (prompt.choiceLabelResolutions[0], Rendered(
            title: resolved.title,
            titleNodes: resolved.titleNodes,
            accessibilityLabel: resolved.accessibilityLabel
        ))
    }

    /// The same label resolution on a legacy (no-presentation) prompt whose title is
    /// catalog text (`finishMulligan`).
    private static func legacyLabel(_ resolution: BasicChoiceLabelResolution) throws -> Rendered {
        let url = try #require(Bundle.module.url(
            forResource: "question-mulligan", withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: Data(contentsOf: url)
        )
        let question = try #require(payload.supportedQuestion)
        let ownerID = BoardTestFixtures.playerID()
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID, hand: [], playerID: ownerID
                ),
            ],
            playerOrder: [investigatorID],
            activeInvestigatorID: investigatorID,
            leadInvestigatorID: investigatorID
        ))
        let prompt = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: ownerID,
                questionVersion: 4,
                rawQuestion: question.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: .supported(question),
            choiceLabelResolutions: [0: resolution],
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        let resolved = prompt.resolvedChoiceLabel(for: question.choices[0], in: projection)
        return Rendered(
            title: resolved.title,
            titleNodes: resolved.titleNodes,
            accessibilityLabel: resolved.accessibilityLabel
        )
    }

    @Test("An icon-less label's raw variable placeholders format on semantic prompts")
    @MainActor
    func iconlessRawPlaceholderLabelMatchesLegacy() async throws {
        let (resolution, semantic) = try await Self.semanticLabel(
            "$label.placeNote place=s:\"{skull} {asterisk}\""
        )
        // The resolver leaves the raw title for the prompt to format.
        #expect(resolution == .resolved("Investigate {skull} {asterisk}"))
        #expect(semantic == Rendered(
            title: "Investigate Skull *",
            titleNodes: [.text("Investigate "), .semanticIcon(.chaosToken(.skull)), .text(" *")],
            accessibilityLabel: "Investigate Skull *"
        ))
        #expect(try Self.legacyLabel(#require(resolution)) == semantic)
    }

    @Test("A label with icon nodes formats a variable's raw placeholders into nodes")
    @MainActor
    func iconRawPlaceholderLabelMatchesLegacy() async throws {
        let (resolution, semantic) = try await Self.semanticLabel(
            "$label.iconPlaceNote place=s:\"{skull} {runeM} {asterisk}\""
        )
        let nodes: [StoryNode] = [
            .text("Spend "), .icon("action"), .text(" at "),
            .semanticIcon(.chaosToken(.skull)), .text(" "), .icon("rune-M"), .text(" *"),
        ]
        #expect(resolution == .resolved(.init(
            title: "Spend action at skull rune m *", inlineNodes: nodes
        )))
        #expect(semantic == Rendered(
            title: "Spend action at skull rune m *",
            titleNodes: nodes,
            accessibilityLabel: "Spend action at skull rune m *"
        ))
        #expect(try Self.legacyLabel(#require(resolution)) == semantic)
    }

    @Test("A variable run holding an icon and [^N] formats both and raises the marker")
    @MainActor
    func variableRunWithIconAndFootnoteRaisesMarker() async throws {
        let (resolution, semantic) = try await Self.semanticLabel(
            "$label.iconPlaceNote place=s:\"{skull} 1927[^5]\""
        )
        let nodes: [StoryNode] = [
            .text("Spend "), .icon("action"), .text(" at "),
            .semanticIcon(.chaosToken(.skull)), .text(" 1927"), .footnoteMarker("5"),
        ]
        // A spoken title is set only when the label carries a split marker (`hasMarker`).
        #expect(resolution == .resolved(.init(
            title: "Spend action at skull 19275",
            inlineNodes: nodes,
            accessibilityTitle: "Spend action at skull 1927 footnote 5"
        )))
        #expect(semantic == Rendered(
            title: "Spend action at skull 19275",
            titleNodes: nodes,
            accessibilityLabel: "Spend action at skull 1927 footnote 5"
        ))
        #expect(try Self.legacyLabel(#require(resolution)) == semantic)
    }

    @Test("Adjacent variable icons and whitespace-only values keep their exact spacing")
    @MainActor
    func adjacentIconsAndWhitespaceValuesKeepSpacing() async throws {
        let cases: [(String, BasicChoiceResolvedLabelText)] = [
            ("{skull}{fast}", .init(title: "Spend action at skullfast", inlineNodes: [
                .text("Spend "), .icon("action"), .text(" at "),
                .semanticIcon(.chaosToken(.skull)), .icon("fast"),
            ])),
            ("{skull} {fast}", .init(title: "Spend action at skull fast", inlineNodes: [
                .text("Spend "), .icon("action"), .text(" at "),
                .semanticIcon(.chaosToken(.skull)), .text(" "), .icon("fast"),
            ])),
            // No raw placeholder: the run is untouched and only the label edge is trimmed.
            ("   ", .init(title: "Spend action at", inlineNodes: [
                .text("Spend "), .icon("action"), .text(" at"),
            ])),
        ]
        for (value, expected) in cases {
            let (resolution, semantic) = try await Self.semanticLabel(
                "$label.iconPlaceNote place=s:\"\(value)\""
            )
            #expect(resolution == .resolved(expected), Comment(rawValue: value))
            #expect(semantic == Rendered(
                title: expected.title,
                titleNodes: expected.inlineNodes,
                accessibilityLabel: expected.title
            ), Comment(rawValue: value))
        }
    }

    @Test("Labels without raw placeholders keep their resolved title, nodes and spoken label")
    @MainActor
    func labelsWithoutRawPlaceholdersAreUnchanged() async throws {
        // Literal `*x*` from a variable is not a raw placeholder and stays text.
        let (iconless, iconlessSemantic) = try await Self.semanticLabel(
            "$label.placeNote place=s:\"the *gate*\""
        )
        #expect(iconless == .resolved("Investigate the *gate*"))
        #expect(iconlessSemantic == Rendered(
            title: "Investigate the *gate*",
            titleNodes: nil,
            accessibilityLabel: "Investigate the *gate*"
        ))

        let (icon, iconSemantic) = try await Self.semanticLabel(
            "$label.iconPlaceNote place=s:\"the *gate*\""
        )
        let nodes: [StoryNode] = [.text("Spend "), .icon("action"), .text(" at the *gate*")]
        #expect(icon == .resolved(.init(
            title: "Spend action at the *gate*", inlineNodes: nodes
        )))
        #expect(iconSemantic == Rendered(
            title: "Spend action at the *gate*",
            titleNodes: nodes,
            accessibilityLabel: "Spend action at the *gate*"
        ))
    }
}
