@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Live Innsmouth unresolved label bot fences")
struct LiveInnsmouthUnresolvedLabelBotTests {
    @Test("The Amalgam unresolved key label stays visible but the live bot cannot select it")
    @MainActor
    func amalgamKeyChoiceIsNotBotSelectableWhenCatalogMarksLabelUnsupported() async throws {
        let fixture = try Self.fixture()
        let labelModel = try await Self.productionLabelModel()
        let prompt = try Self.prompt(for: fixture, labelModel: labelModel)
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())

        #expect(
            Self.productionCatalogChunkPath
                == "frontend/public/locale-catalog/c/"
                    + Self.productionCatalogChunkSHA256 + ".json"
        )
        #expect(Self.productionCatalogChunkSHA256.count == 64)
        #expect(prompt.displayOrderedChoices().map(\.index) == [0, 1])
        #expect(prompt.choiceLabelResolutions[0] == .unavailable(.unsupportedEntry))
        #expect(prompt.choiceLabelResolutions[1] == .resolved("The Amalgam attacks you"))

        for (index, expectedTitle) in fixture.expectedTitles.enumerated() {
            let choice = try #require(prompt.choices.first { $0.index == index })
            let resolved = prompt.resolvedChoiceLabel(for: choice, in: projection)
            #expect(resolved.title == expectedTitle)
            #expect(
                prompt.isChoiceActionable(choice, in: projection)
                    == fixture.expectedActionable[index]
            )
        }

        #expect(
            liveHarnessSelectableChoiceIndexes(prompt: prompt, projection: projection)
                == fixture.expectedBotSelectableIndexes
        )
    }

    @MainActor
    private static func prompt(
        for fixture: InnsmouthUnresolvedLabelFixture,
        labelModel: AppModel
    ) throws -> BasicChoicePromptPresentation {
        let bound = try fixture.questionPresentation.bind(
            to: fixture.rawQuestion,
            expectedQuestionVersion: fixture.source.questionVersion
        )
        let question = BasicChoiceParser.parseQuestion(fixture.rawQuestion)
        let labelResolutions = labelModel.choiceLabelResolutions(
            for: question.supportedQuestion,
            semanticPresentation: bound
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: fixture.source.questionVersion,
                rawQuestion: fixture.rawQuestion,
                questionPresentation: fixture.questionPresentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: question,
            semanticPresentation: bound,
            semanticLocaleIdentifier: "en",
            choiceLabelResolutions: labelResolutions,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    @MainActor
    private static func productionLabelModel() async throws -> AppModel {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            pack: "innsmouth",
            entryKeys: [
                "theInnsmouthConspiracy.thePitOfDespair.label.placeKeyOnTheAmalgam",
                "theInnsmouthConspiracy.thePitOfDespair.label.theAmalgamAttacksYou",
            ],
            unsupportedKeys: 1,
            chunkEntries: Self.syntheticInnsmouthLabelChunkEntries
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [documents.profile], selectedID: documents.profile.id
            ),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        model.localeCatalog = try await documents.loadSnapshot()
        model.localeCatalogRequest = LocaleCatalogRequest(
            profileID: model.selectedProfile.id,
            advertisement: documents.advertisement
        )
        return model
    }

    private static func fixture() throws -> InnsmouthUnresolvedLabelFixture {
        let url = try #require(Bundle.module.url(
            forResource: "roland-c07041-q76-amalgam-key-unresolved-label",
            withExtension: "json",
            subdirectory: "Fixtures/LiveInnsmouthPlaythrough"
        ))
        return try ContractJSON.decode(
            InnsmouthUnresolvedLabelFixture.self,
            from: Data(contentsOf: url)
        )
    }

    private static let productionCatalogChunkPath = "frontend/public/locale-catalog/c/"
        + "5a9eda19b1ab3c96e74d4fda925d9b413cd900e4837076c4098170682a1c9ec3.json"
    private static let productionCatalogChunkSHA256 =
        "5a9eda19b1ab3c96e74d4fda925d9b413cd900e4837076c4098170682a1c9ec3"

    // Synthetic two-entry catalog chunk extracted from the English production chunk above.
    private static let syntheticInnsmouthLabelChunkEntries = #"""
    {
      "theInnsmouthConspiracy.thePitOfDespair.label.placeKeyOnTheAmalgam": {
        "form": "unsupported",
        "reason": "unusable-variable-type",
        "detail": "key is unknown for a text slot"
      },
      "theInnsmouthConspiracy.thePitOfDespair.label.theAmalgamAttacksYou": {
        "form": "message",
        "nodes": [
          {"type": "text", "value": "The Amalgam attacks you"}
        ],
        "variables": []
      }
    }
    """#
}

private struct InnsmouthUnresolvedLabelFixture: Decodable, Sendable {
    let source: Source
    let expectedBotSelectableIndexes: [Int]
    let expectedTitles: [String]
    let expectedActionable: [Bool]
    let rawQuestion: JSONValue
    let questionPresentation: QuestionPresentation

    struct Source: Decodable, Sendable {
        let questionVersion: Int
    }
}
