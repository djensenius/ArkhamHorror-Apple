@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Live NotZ semantic choice rendering")
struct LiveNotZSemanticChoiceRenderingTests {
    @Test("Captured semantic choices render through the prompt presentation path")
    @MainActor
    func capturedSemanticChoicesRenderThroughPromptPresentationPath() async throws {
        let samples = try Self.renderingSamples()
        #expect(Set(samples.map(\.kind)) == [
            "advanceAgenda",
            "assignDamage",
            "assignHorror",
            "chooseTarget",
            "componentLabel",
            "localizedLabel",
            "move",
            "resolveForcedAbility",
            "useAbility",
        ])
        let projection = try Self.capturedProjection()
        let labelModel = try await Self.productionLabelModel()

        for sample in samples {
            try Self.assertSampleRenders(sample, projection: projection, labelModel: labelModel)
        }
    }

    @MainActor
    private static func assertSampleRenders(
        _ sample: RenderingSample,
        projection: BoardProjection,
        labelModel: AppModel
    ) throws {
        let prompt = try Self.prompt(for: sample, labelModel: labelModel)
        let choice = try #require(
            prompt.choices.first { $0.index == sample.source.choiceIndex },
            "\(sample.kind) captured choice is present"
        )
        let resolved = prompt.resolvedChoiceLabel(for: choice, in: projection)

        #expect(prompt.isRenderableQuestion, "\(sample.kind) prompt is renderable")
        #expect(prompt.canSubmit, "\(sample.kind) prompt remains submittable")
        #expect(
            prompt.displayOrderedChoices().map(\.index).contains(choice.index),
            "\(sample.kind) captured choice is displayed"
        )
        #expect(
            prompt.isChoiceActionable(choice, in: projection),
            "\(sample.kind) captured choice is actionable"
        )
        #expect(
            resolved.title == sample.expectedTitle,
            "\(sample.kind) BasicChoicePromptView title comes from the semantic presentation"
        )
        #expect(
            resolved.title != "Update required",
            "\(sample.kind) does not render Update required"
        )
        #expect(
            resolved.systemImage == sample.expectedSystemImage,
            "\(sample.kind) uses the semantic icon rendered by BasicChoicePromptView"
        )
        #expect(
            prompt.accessibilityHint(for: choice, in: projection)
                == "Activates choice \(choice.index + 1).",
            "\(sample.kind) keeps single-choice actionability semantics"
        )
    }

    @Test("Unresolved captured catalog labels remain visible but not pressable")
    @MainActor
    func unresolvedCapturedCatalogLabelsRemainUnpressable() async throws {
        let sample = try Self.traumaSample()
        let prompt = try await Self.prompt(
            for: sample,
            labelModel: Self.productionLabelModel(
                entryKeys: ["continue"],
                chunkEntries: Self.productionContinueOnlyChunkEntries
            )
        )
        let projection = try Self.capturedProjection()
        let choice = try #require(prompt.choices.first { $0.index == sample.source.choiceIndex })
        let resolved = prompt.resolvedChoiceLabel(for: choice, in: projection)

        #expect(resolved.title == "Choice 1")
        #expect(!prompt.isChoiceActionable(choice, in: projection))
        #expect(
            prompt.accessibilityHint(for: choice, in: projection)
                == "This server publishes no usable text for this choice."
        )
    }

    @Test("Captured catalog labels with unbound variables remain unpressable")
    @MainActor
    func capturedCatalogLabelsWithUnboundVariablesRemainUnpressable() async throws {
        let sample = try Self.traumaSample()
        let prompt = try await Self.prompt(
            for: sample,
            labelModel: Self.productionLabelModel(
                entryKeys: ["continue", "label.sufferPhysicalTrauma"],
                chunkEntries: Self.productionUnboundCountLabelChunkEntries
            )
        )
        let projection = try Self.capturedProjection()
        let choice = try #require(prompt.choices.first { $0.index == sample.source.choiceIndex })
        let resolved = prompt.resolvedChoiceLabel(for: choice, in: projection)

        #expect(resolved.title == "Choice 1")
        #expect(!prompt.isChoiceActionable(choice, in: projection))
        #expect(
            prompt.choiceLabelResolutions[choice.index]
                == BasicChoiceLabelResolution.unavailable(.missingVariable)
        )
    }

    @Test("Hidden hand card entities do not reveal catalog names")
    @MainActor
    func hiddenHandCardEntitiesDoNotRevealCatalogNames() async throws {
        let sample = try Self.heirloomTargetSample()
        let prompt = try await Self.prompt(for: sample, labelModel: Self.productionLabelModel())
        let projection = try Self.capturedProjection()
        let entity = QuestionPresentation.Entity(
            kind: .card,
            id: "22816a3f-6d54-4e49-bee9-a7c3a99e03e9"
        )

        #expect(prompt.semanticEntityTitle(entity, in: projection) == "Heirloom of Hyperborea")
        #expect(prompt.semanticEntityTitle(
            entity,
            in: projection,
            revealsHandCardFaces: false
        ) == nil)
    }

    @Test("AppModel passes the card catalog into basic choice presentation")
    @MainActor
    func appModelPassesCardCatalogIntoBasicChoicePresentation() async throws {
        let sample = try Self.heirloomTargetSample()
        let ownerID = BoardTestFixtures.playerID("000000000001")
        let bound = try sample.questionPresentation.bind(
            to: sample.rawQuestion,
            expectedQuestionVersion: sample.source.questionVersion
        )
        let question = BasicChoiceParser.parseQuestion(sample.rawQuestion)
        let payload = BasicChoiceQuestionPayload(
            rawValue: sample.rawQuestion,
            state: question,
            presentation: bound
        )
        let projection = try Self.capturedProjection(questionPayload: payload)
        let gameID = BoardTestFixtures.gameID()
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [.hosted],
                selectedID: ServerProfile.hosted.id
            ),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        model.cardCatalog = try Self.capturedCardCatalog()
        model.liveGameStates[gameID] = LiveGameState.live(projection)
        model.liveGameParticipantIdentities[gameID] = LiveGameParticipantIdentity.participant(ownerID)

        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let choice = try #require(prompt.choices.first { $0.index == sample.source.choiceIndex })
        #expect(prompt.resolvedChoiceLabel(for: choice, in: projection).title == sample.expectedTitle)
    }

    @MainActor
    private static func prompt(
        for sample: RenderingSample,
        labelModel: AppModel,
        choiceLabelResolutions overrideResolutions: [Int: BasicChoiceLabelResolution]? = nil
    ) throws -> BasicChoicePromptPresentation {
        let bound = try sample.questionPresentation.bind(
            to: sample.rawQuestion,
            expectedQuestionVersion: sample.source.questionVersion
        )
        let cardCatalog = try capturedCardCatalog()
        let question = BasicChoiceParser.parseQuestion(sample.rawQuestion)
        let labelResolutions = overrideResolutions ?? labelModel.choiceLabelResolutions(
            for: question.supportedQuestion,
            semanticPresentation: bound
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: sample.source.questionVersion,
                rawQuestion: sample.rawQuestion,
                questionPresentation: sample.questionPresentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: question,
            semanticPresentation: bound,
            semanticLocaleIdentifier: "en",
            cardCatalog: cardCatalog,
            choiceLabelResolutions: labelResolutions,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private static func renderingSamples() throws -> [RenderingSample] {
        let url = try #require(Bundle.module.url(
            forResource: "render-choice-kind-samples",
            withExtension: "json",
            subdirectory: "Fixtures/LiveNightOfTheZealotPlaythrough"
        ))
        let fixture = try ContractJSON.decode(RenderingSamplesFixture.self, from: Data(
            contentsOf: url
        ))
        return fixture.samples
    }

    private static func traumaSample() throws -> RenderingSample {
        try #require(renderingSamples().first {
            $0.expectedTitle == "Suffer physical trauma"
        })
    }

    private static func heirloomTargetSample() throws -> RenderingSample {
        try #require(renderingSamples().first {
            $0.expectedTitle == "Choose Heirloom of Hyperborea"
        })
    }

    private static func capturedProjection(
        questionPayload: BasicChoiceQuestionPayload? = nil
    ) throws -> BoardProjection {
        let agnesID = BoardTestFixtures.investigatorID("c01004")
        let wendyID = BoardTestFixtures.investigatorID("c01005")
        let locationID = try semanticLocationID("01581c53-86ca-4a88-a192-ab1a2d2775e0")
        let agnesPlayerID = BoardTestFixtures.playerID("000000000001")
        let heirloomUUID = try #require(UUID(
            uuidString: "22816a3f-6d54-4e49-bee9-a7c3a99e03e9"
        ))
        let heirloomID = WireCardID(heirloomUUID)
        let heirloom = playerCard(
            id: heirloomID,
            code: "c01012",
            title: "Card c01012"
        )
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: [(
                locationID,
                .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: locationID,
                    label: "Captured location"
                ))
            )],
            investigators: [
                agnesID: BoardTestFixtures.investigator(
                    id: agnesID,
                    name: CardName(title: "Captured investigator", subtitle: nil),
                    hand: [heirloom],
                    playerID: agnesPlayerID
                ),
                wendyID: BoardTestFixtures.investigator(
                    id: wendyID,
                    name: CardName(title: "Captured mover", subtitle: nil),
                    playerID: BoardTestFixtures.playerID("000000000002")
                ),
            ],
            playerOrder: [agnesID, wendyID],
            cardValues: [heirloomID: heirloom],
            questions: questionPayload.map { [agnesPlayerID: $0] } ?? [:]
        ))
    }

    private static func playerCard(id: WireCardID, code: String, title: String) -> JSONValue {
        .object([
            "tag": .string("PlayerCard"),
            "contents": .object([
                "id": .string(id.codingKey.stringValue),
                "cardCode": .string(code),
                "name": .object(["title": .string(title)]),
            ]),
        ])
    }

    private static func capturedCardCatalog() throws -> CardCatalogSnapshot {
        try CardCatalogSnapshot(namesByCode: [
            CardCode("c01012"): CardName(title: "Heirloom of Hyperborea", subtitle: nil),
            CardCode("c01013"): CardName(title: "Captured ability card", subtitle: nil),
            CardCode("c01164"): CardName(title: "Captured treachery", subtitle: nil),
        ])
    }

    @MainActor
    private static func productionLabelModel(
        entryKeys: [String] = [
            "continue", "label.sufferPhysicalTrauma", "label.sufferMentalTrauma",
        ],
        chunkEntries: String = productionLabelChunkEntries
    ) async throws -> AppModel {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            pack: "label",
            entryKeys: entryKeys,
            chunkEntries: chunkEntries
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

    private static let productionLabelChunkEntries = #"""
    {
      "continue": {
        "form":"message",
        "nodes":[{"type":"text","value":"Continue"}],
        "variables":[]
      },
      "label.sufferPhysicalTrauma": {
        "form":"plural",
        "cases":[
          [{"type":"text","value":"Suffer physical trauma"}],
          [
            {"type":"text","value":"Suffer "},
            {"type":"var","name":"count","source":"named","role":"text"},
            {"type":"text","value":" physical trauma"}
          ]
        ],
        "variables":[{"name":"count","source":"named","role":"text"}]
      },
      "label.sufferMentalTrauma": {
        "form":"plural",
        "cases":[
          [{"type":"text","value":"Suffer mental trauma"}],
          [
            {"type":"text","value":"Suffer "},
            {"type":"var","name":"count","source":"named","role":"text"},
            {"type":"text","value":" mental trauma"}
          ]
        ],
        "variables":[{"name":"count","source":"named","role":"text"}]
      }
    }
    """#

    private static let productionContinueOnlyChunkEntries = #"""
    {
      "continue": {
        "form":"message",
        "nodes":[{"type":"text","value":"Continue"}],
        "variables":[]
      }
    }
    """#

    private static let productionUnboundCountLabelChunkEntries = #"""
    {
      "continue": {
        "form":"message",
        "nodes":[{"type":"text","value":"Continue"}],
        "variables":[]
      },
      "label.sufferPhysicalTrauma": {
        "form":"message",
        "nodes":[
          {"type":"text","value":"Take "},
          {"type":"var","name":"count","source":"named","role":"text"},
          {"type":"text","value":" damage"}
        ],
        "variables":[{"name":"count","source":"named","role":"text"}]
      }
    }
    """#

    private static func semanticLocationID(_ raw: String) throws -> LocationID {
        try #require(LocationID(codingKey: AnyCodingKey(stringValue: raw)))
    }
}

private struct RenderingSamplesFixture: Decodable, Sendable {
    let samples: [RenderingSample]
}

private struct RenderingSample: Decodable, Sendable {
    let kind: String
    let source: RenderingSampleSource
    let expectedTitle: String
    let rawQuestion: JSONValue
    let questionPresentation: QuestionPresentation

    var expectedSystemImage: String {
        switch kind {
        case "advanceAgenda": "arrow.up.circle.fill"
        case "assignDamage": "heart.slash.fill"
        case "assignHorror": "brain.head.profile.fill"
        case "chooseTarget": "scope"
        case "componentLabel": "circle.grid.cross"
        case "localizedLabel": "text.bubble.fill"
        case "move": "figure.walk"
        case "resolveForcedAbility": "exclamationmark.triangle.fill"
        case "useAbility": "bolt.circle.fill"
        default: "questionmark.square.dashed"
        }
    }
}

private struct RenderingSampleSource: Decodable, Sendable {
    let questionVersion: Int
    let choiceIndex: Int
}
