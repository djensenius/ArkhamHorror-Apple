@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Live NotZ typed label variable rendering")
struct LiveNotZTypedLabelVariableTests {
    @Test("Roland c01142 q16 typed label variables resolve through the production catalog")
    @MainActor
    func rolandTypedLabelVariablesResolveThroughProductionCatalog() async throws {
        let fixture = try Self.fixture()
        let labelModel = try await Self.productionLabelModel()
        let prompt = try Self.prompt(for: fixture, labelModel: labelModel)
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())

        #expect(prompt.canSubmit)
        #expect(prompt.displayOrderedChoices().map(\.index) == [0, 1])

        for (index, expectedTitle) in fixture.expectedTitles.enumerated() {
            let choice = try #require(prompt.choices.first { $0.index == index })
            let resolved = prompt.resolvedChoiceLabel(for: choice, in: projection)
            #expect(resolved.title == expectedTitle)
            #expect(prompt.isChoiceActionable(choice, in: projection))
            #expect(
                prompt.accessibilityHint(for: choice, in: projection)
                    == "Activates choice \(index + 1)."
            )
        }
    }

    @Test("Icon variable choice labels resolve through the production label path")
    @MainActor
    func iconVariableChoiceLabelResolvesAndStaysPressable() async throws {
        let fixture = try Self.fixture().replacingChoiceLabel(
            at: 0,
            with: "$label.test skill=s:\"willpower\" count=i:3.0"
        )
        let labelModel = try await Self.productionLabelModel()
        let prompt = try Self.prompt(for: fixture, labelModel: labelModel)
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let choice = try #require(prompt.choices.first { $0.index == 0 })
        let resolved = prompt.resolvedChoiceLabel(for: choice, in: projection)

        #expect(resolved.title == "Test willpower (3)")
        #expect(prompt.isChoiceActionable(choice, in: projection))
        #expect(prompt.choiceLabelResolutions[0] == .resolved("Test willpower (3)"))
    }

    @Test("Bad icon variable values leave choice labels unresolved and unpressable")
    @MainActor
    func badIconVariableChoiceLabelValueRemainsUnresolved() async throws {
        let fixture = try Self.fixture().replacingChoiceLabel(
            at: 0,
            with: "$label.test skill=s:\"wild\" count=i:3.0"
        )
        let labelModel = try await Self.productionLabelModel()
        let prompt = try Self.prompt(for: fixture, labelModel: labelModel)
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let choice = try #require(prompt.choices.first { $0.index == 0 })
        let resolved = prompt.resolvedChoiceLabel(for: choice, in: projection)

        #expect(resolved.title == "Choice 1")
        #expect(!prompt.isChoiceActionable(choice, in: projection))
        #expect(prompt.choiceLabelResolutions[0] == .unavailable(.unsupportedVariableValue))
    }

    @Test("Malformed typed label variables remain unresolved and unpressable")
    @MainActor
    func malformedTypedLabelVariableRemainsUnresolved() async throws {
        let fixture = try Self.fixture().replacingChoiceLabel(
            at: 0,
            with: "$label.discardCardsFromHand count=i:not-a-number"
        )
        let labelModel = try await Self.productionLabelModel()
        let prompt = try Self.prompt(for: fixture, labelModel: labelModel)
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let choice = try #require(prompt.choices.first { $0.index == 0 })
        let resolved = prompt.resolvedChoiceLabel(for: choice, in: projection)

        #expect(resolved.title == "Choice 1")
        #expect(!prompt.isChoiceActionable(choice, in: projection))
        #expect(
            prompt.choiceLabelResolutions[0]
                == BasicChoiceLabelResolution.unavailable(.unsupportedVariableValue)
        )
        #expect(
            prompt.accessibilityHint(for: choice, in: projection)
                == "The text for this choice needs a value this app cannot display."
        )
    }

    @MainActor
    private static func prompt(
        for fixture: TypedLabelFixture,
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
            pack: "label",
            entryKeys: [
                "label.discardCardsFromHand",
                "label.takeDamageAndHorror",
                "label.test",
            ],
            chunkEntries: Self.productionLabelChunkEntries
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

    private static func fixture() throws -> TypedLabelFixture {
        let url = try #require(Bundle.module.url(
            forResource: "roland-c01142-q16-typed-label-vars",
            withExtension: "json",
            subdirectory: "Fixtures/LiveNightOfTheZealotPlaythrough"
        ))
        return try ContractJSON.decode(TypedLabelFixture.self, from: Data(contentsOf: url))
    }

    private static let productionLabelChunkEntries = #"""
    {
      "label.discardCardsFromHand": {
        "form":"plural",
        "cases":[
          [{"type":"text","value":"Choose and discard 1 card from your hand"}],
          [
            {"type":"text","value":"Choose and discard "},
            {"type":"var","name":"count","source":"named","role":"text"},
            {"type":"text","value":" cards from your hand"}
          ]
        ],
        "variables":[{"name":"count","source":"named","role":"text"}]
      },
      "label.takeDamageAndHorror": {
        "form":"message",
        "nodes":[
          {"type":"text","value":"Take "},
          {"type":"var","name":"damage","source":"named","role":"text"},
          {"type":"text","value":" damage and "},
          {"type":"var","name":"horror","source":"named","role":"text"},
          {"type":"text","value":" horror"}
        ],
        "variables":[
          {"name":"damage","source":"named","role":"text"},
          {"name":"horror","source":"named","role":"text"}
        ]
      },
      "label.test": {
        "form":"message",
        "nodes":[
          {"type":"text","value":"Test "},
          {"type":"var","name":"skill","source":"named","role":"iconVariable"},
          {"type":"text","value":" ("},
          {"type":"var","name":"count","source":"named","role":"text"},
          {"type":"text","value":")"}
        ],
        "variables":[
          {"name":"skill","source":"named","role":"iconVariable"},
          {"name":"count","source":"named","role":"text"}
        ]
      }
    }
    """#
}

private struct TypedLabelFixture: Decodable, Sendable {
    let source: Source
    let expectedTitles: [String]
    let rawQuestion: JSONValue
    let questionPresentation: QuestionPresentation

    struct Source: Decodable, Sendable {
        let questionVersion: Int
    }

    func replacingChoiceLabel(at index: Int, with label: String) throws -> TypedLabelFixture {
        let rawQuestion = try replacingRawQuestionLabel(at: index, with: label)
        let questionPresentation = try replacingPresentationLabel(at: index, with: label)
        return TypedLabelFixture(
            source: source,
            expectedTitles: expectedTitles,
            rawQuestion: rawQuestion,
            questionPresentation: questionPresentation
        )
    }

    private func replacingRawQuestionLabel(at index: Int, with label: String) throws -> JSONValue {
        guard case var .object(object) = rawQuestion,
              case var .array(choices)? = object["choices"],
              choices.indices.contains(index),
              case var .object(choice) = choices[index]
        else { throw TestFailure() }
        choice["label"] = .string(label)
        choices[index] = .object(choice)
        object["choices"] = .array(choices)
        return .object(object)
    }

    private func replacingPresentationLabel(
        at index: Int,
        with label: String
    ) throws -> QuestionPresentation {
        var choices = questionPresentation.choices
        guard choices.indices.contains(index) else { throw TestFailure() }
        choices[index] = choices[index].replacingLabel(label)
        return QuestionPresentation(
            protocolVersion: questionPresentation.protocolVersion,
            questionVersion: questionPresentation.questionVersion,
            questionKind: questionPresentation.questionKind,
            choiceCount: questionPresentation.choiceCount,
            choices: choices,
            answer: questionPresentation.answer,
            selection: questionPresentation.selection,
            groups: questionPresentation.groups,
            label: questionPresentation.label,
            questionLabel: questionPresentation.questionLabel,
            completionLabel: questionPresentation.completionLabel,
            confirmLabel: questionPresentation.confirmLabel,
            backLabel: questionPresentation.backLabel,
            cardCode: questionPresentation.cardCode,
            payCost: questionPresentation.payCost,
            questionSource: questionPresentation.questionSource,
            tooltip: questionPresentation.tooltip,
            flavorText: questionPresentation.flavorText,
            readCards: questionPresentation.readCards,
            readChoiceKind: questionPresentation.readChoiceKind,
            target: questionPresentation.target,
            resolveTarget: questionPresentation.resolveTarget,
            amountChoices: questionPresentation.amountChoices,
            paymentChoices: questionPresentation.paymentChoices,
            usedInvestigators: questionPresentation.usedInvestigators,
            pointsRemaining: questionPresentation.pointsRemaining,
            chosenSupplies: questionPresentation.chosenSupplies,
            resupply: questionPresentation.resupply,
            drawings: questionPresentation.drawings,
            key: questionPresentation.key,
            value: questionPresentation.value,
            source: questionPresentation.source,
            fromInvestigator: questionPresentation.fromInvestigator,
            fromInitialAmount: questionPresentation.fromInitialAmount,
            toInvestigator: questionPresentation.toInvestigator,
            toInitialAmount: questionPresentation.toInitialAmount,
            token: questionPresentation.token
        )
    }
}

private extension QuestionPresentation.Choice {
    func replacingLabel(_ text: String) -> QuestionPresentation.Choice {
        QuestionPresentation.Choice(
            sourceIndex: sourceIndex,
            kind: kind,
            selectable: selectable,
            completesSelection: completesSelection,
            actorID: actorID,
            entity: entity,
            label: QuestionPresentation.Label(kind: .embeddedI18n, text: text),
            ability: ability,
            cost: cost,
            flippable: flippable,
            face: face,
            key: key,
            skillType: skillType,
            connection: connection,
            tarotCard: tarotCard,
            component: component,
            source: source,
            step: step,
            tooltip: tooltip,
            cards: cards,
            flavorText: flavorText,
            uiTag: uiTag,
            target: target,
            groupIndex: groupIndex
        )
    }
}
