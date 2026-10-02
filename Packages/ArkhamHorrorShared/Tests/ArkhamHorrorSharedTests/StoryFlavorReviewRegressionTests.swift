@testable import ArkhamHorrorShared
import Foundation
import Testing

// swiftlint:disable line_length
@MainActor
extension AppModelLiveGameTests {
    // JSON below mirrors server constructors in Arkham/Text.hs:48-70 and JSON derivation in
    // Arkham/Text.hs:129-161 (tag plus flattened fields, EntrySplit as tag-only).
    private var reviewFlavorBody: [JSONValue] {
        [
            .object(["tag": .string("BasicEntry"), "text": .string("$story.basic")]),
            .object(["tag": .string("HeaderEntry"), "level": .number(Self.number("2")), "key": .string("story.heading")]),
            .object(["tag": .string("I18nEntry"), "key": .string("story.i18n"), "variables": .object(["name": .string("Daisy")])]),
            .object(["tag": .string("ModifyEntry"), "modifiers": .array([.string("BlueEntry"), .string("FutureEntry")]), "entry": .object(["tag": .string("BasicEntry"), "text": .string("Modified")])]),
            .object(["tag": .string("CompositeEntry"), "entries": .array([.object(["tag": .string("BasicEntry"), "text": .string("Composite A")])])]),
            .object(["tag": .string("ColumnEntry"), "entries": .array([.object(["tag": .string("BasicEntry"), "text": .string("Column A")])])]),
            .object(["tag": .string("ListEntry"), "list": .array([.object(["entry": .object(["tag": .string("I18nEntry"), "key": .string("story.listItem"), "variables": .object([:])]), "nested": .array([]), "extra": .bool(true)])])]),
            .object(["tag": .string("CardEntry"), "cardCode": .string("c01159"), "imageModifiers": .array([.string("SmallImage"), .string("FutureImage")])]),
            .object(["tag": .string("TarotEntry"), "tarot": .string("TheFool0")]),
            .object(["tag": .string("ChaosTokenEntry"), "chaosTokenFace": .string("Skull")]),
            .object(["tag": .string("ChaosTokenMorphEntry"), "morphFrom": .string("Skull"), "morphTo": .string("Cultist")]),
            .object(["tag": .string("EntrySplit"), "extra": .string("ignored")]),
            .object(["tag": .string("FutureEntry"), "text": .string("Future readable text"), "extra": .number(Self.number("1"))]),
        ]
    }

    private static func number(_ text: String) -> JSONNumber {
        // swiftlint:disable:next force_try
        try! JSONNumber(exactDecimalLiteral: text)
    }

    @Test("Semantic presentation flavor path renders every server entry shape with a catalog")
    func semanticPresentationFlavorPathRendersAllEntriesWithCatalog() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["story.basic", "story.heading", "story.i18n", "story.listItem", "story.title"],
            chunkEntries: """
            {"story.title":{"form":"message","nodes":[{"type":"text","value":"Catalog title"}],"variables":[]},\
            "story.basic":{"form":"message","nodes":[{"type":"text","value":"Catalog basic"}],"variables":[]},\
            "story.heading":{"form":"message","nodes":[{"type":"text","value":"Catalog heading"}],"variables":[]},\
            "story.i18n":{"form":"message","nodes":[{"type":"text","value":"Catalog i18n"}],"variables":[]},\
            "story.listItem":{"form":"message","nodes":[{"type":"text","value":"Catalog list item"}],"variables":[]}}
            """
        )
        let (model, _) = makeCatalogSignedInModel(documents: documents)
        await model.flowTask?.value
        await model.localeCatalogTask?.value
        let flavorText = QuestionPresentation.FlavorText(title: "$story.title", body: reviewFlavorBody)
        let resolution = try #require(model.storyResolution(for: flavorText)?.story)
        #expect(resolution.title == "Catalog title")
        #expect(resolution.body.count == 13)
        #expect(resolution.body[0] == .nodes([.text("Catalog basic")]))
        #expect(resolution.body[1] == .heading(level: FlavorTextHeadingLevel(rawValue: 2), nodes: [.text("Catalog heading")]))
        #expect(resolution.body[2] == .nodes([.text("Catalog i18n")]))
        #expect(resolution.body[3] == .modified(modifiers: [.blueEntry], entry: .text("Modified")))
        #expect(resolution.body[4] == .composite(entries: [.text("Composite A")]))
        #expect(resolution.body[5] == .columns(entries: [.text("Column A")]))
        #expect(resolution.body[6] == .list(items: [
            ResolvedStoryListItem(entry: .nodes([.text("Catalog list item")]), nested: []),
        ]))
        #expect(resolution.body[7] == .cardReference(
            cardCode: BoardTestFixtures.cardCode("c01159"),
            imageModifiers: [.smallImage]
        ))
        #expect(resolution.body[8] == .tarotReference(arcana: "TheFool0"))
        #expect(resolution.body[9] == .chaosTokenReference(face: .skull))
        #expect(resolution.body[10] == .chaosTokenMorph(from: .skull, target: .cultist))
        #expect(resolution.body[11] == .divider)
        #expect(resolution.body[12] == .text("Future readable text"))
    }

    @Test("Semantic presentation flavor path falls back readably without a catalog")
    func semanticPresentationFlavorPathFallsBackWithoutCatalog() async throws {
        let (model, _) = makeSignedInModel()
        await model.flowTask?.value
        let flavorText = QuestionPresentation.FlavorText(title: "$story.title", body: reviewFlavorBody)
        let resolution = try #require(model.storyResolution(for: flavorText)?.story)
        #expect(resolution.title == "story.title")
        #expect(resolution.body[0] == .text("story.basic"))
        #expect(resolution.body[1] == .heading(
            level: FlavorTextHeadingLevel(rawValue: 2),
            nodes: [.text("story.heading")]
        ))
        #expect(resolution.body[2] == .text("story.i18n (name: Daisy)"))
        #expect(resolution.body[3] == .modified(modifiers: [.blueEntry], entry: .text("Modified")))
        #expect(resolution.body[4] == .composite(entries: [.text("Composite A")]))
        #expect(resolution.body[5] == .columns(entries: [.text("Column A")]))
        #expect(resolution.body[6] == .list(items: [
            ResolvedStoryListItem(entry: .text("story.listItem"), nested: []),
        ]))
        #expect(resolution.body[7] == .cardReference(
            cardCode: BoardTestFixtures.cardCode("c01159"),
            imageModifiers: [.smallImage]
        ))
        #expect(resolution.body[8] == .tarotReference(arcana: "TheFool0"))
        #expect(resolution.body[9] == .chaosTokenReference(face: .skull))
        #expect(resolution.body[10] == .chaosTokenMorph(from: .skull, target: .cultist))
        #expect(resolution.body[11] == .divider)
        #expect(resolution.body[12] == .text("Future readable text"))
    }

    @Test("Catalog loading, loaded, and failed states have the approved prompt behavior")
    func catalogFirstLoadStatesDriveStoryPromptBehavior() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["setup", "shuffleRemainder", "nightOfTheZealot.theGathering.setup.gatherSets", "nightOfTheZealot.theGathering.setup.placeLocations", "nightOfTheZealot.theGathering.setup.setOutOfPlay"],
            chunkEntries: """
            {"setup":{"form":"message","nodes":[{"type":"text","value":"Setup"}],"variables":[]},\
            "nightOfTheZealot.theGathering.setup.gatherSets":{"form":"message","nodes":[{"type":"text","value":"Gather sets"}],"variables":[]},\
            "nightOfTheZealot.theGathering.setup.placeLocations":{"form":"message","nodes":[{"type":"text","value":"Place locations"}],"variables":[]},\
            "nightOfTheZealot.theGathering.setup.setOutOfPlay":{"form":"message","nodes":[{"type":"text","value":"Set aside"}],"variables":[]},\
            "shuffleRemainder":{"form":"message","nodes":[{"type":"text","value":"Shuffle"}],"variables":[]}}
            """
        )
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(model: model, fakes: fakes, envelope: envelope, connection: connection)
        let readQuestion = try loadContractFixtureValue("question-read")
        let readUpdate = try snapshotUpdate(from: envelope, scenarioSteps: envelope.game.scenarioSteps + 1, replacingQuestionWith: readQuestion)
        try await connection.enqueue(.event(.message(ContractJSON.encode(readUpdate))))
        await connection.waitUntilAwaitingNextEvent()
        let request = LocaleCatalogRequest(profileID: model.selectedProfile.id, advertisement: documents.advertisement)

        model.localeCatalogRequest = request
        model.localeCatalogFailure = nil
        model.isLocaleCatalogLoading = true
        var presentation = try #require(model.basicChoicePresentation(for: gameID))
        #expect(presentation.storyResolution == .unavailable(.loading))
        #expect(presentation.statusMessage == "Loading story…")
        #expect(!presentation.canSubmit)

        model.isLocaleCatalogLoading = false
        model.localeCatalog = try await documents.loadSnapshot()
        presentation = try #require(model.basicChoicePresentation(for: gameID))
        #expect(presentation.storyResolution?.story?.title == "Setup")
        let loadedFirstEntry: ResolvedStoryEntry? = {
            guard case let .list(items)? = presentation.storyResolution?.story?.body.first else {
                return nil
            }
            return items.first?.entry
        }()
        #expect(loadedFirstEntry == .nodes([.text("Gather sets")]))
        #expect(presentation.canSubmit)

        model.localeCatalog = nil
        model.localeCatalogFailure = .transportFailure
        presentation = try #require(model.basicChoicePresentation(for: gameID))
        #expect(presentation.storyResolution?.story?.title == "Setup")
        let fallbackFirstEntry: ResolvedStoryEntry? = {
            guard case let .list(items)? = presentation.storyResolution?.story?.body.first else {
                return nil
            }
            return items.first?.entry
        }()
        #expect(fallbackFirstEntry == .text(
            "nightOfTheZealot.theGathering.setup.gatherSets"
        ))
        #expect(presentation.canSubmit)
        #expect(presentation.catalogRetry != nil)
    }
}

extension BasicChoiceSemanticPresentationTests {
    @Test("Semantic story summaries include card names and structured fallback text")
    func semanticStorySummariesUseReadableEntries() throws {
        let payload = try rawPayload("question-gathering-act-advance")
        let cardCode = BoardTestFixtures.cardCode("c01159")
        let choice = QuestionPresentation.Choice(
            sourceIndex: 0,
            kind: .info,
            flavorText: .init(title: nil, body: [])
        )
        let presentation = QuestionPresentation(
            protocolVersion: 2,
            questionVersion: 135,
            questionKind: .chooseOne,
            choiceCount: 1,
            choices: [choice]
        )
        let bound = try presentation.bind(to: payload.rawValue, expectedQuestionVersion: 135)
        let prompt = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 135,
                rawQuestion: payload.rawValue,
                questionPresentation: presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            semanticPresentation: bound,
            cardCatalog: CardCatalogSnapshot(namesByCode: [cardCode: CardName(title: "Lita Chantler", subtitle: nil)]),
            choiceFlavorResolutions: [0: .resolved(ResolvedStory(
                title: nil,
                body: [.composite(entries: [
                    .heading(level: .level1, nodes: [.text("Heading text")]),
                    .modified(modifiers: [.blueEntry], entry: .text("Modified text")),
                    .columns(entries: [.text("Column A"), .text("Column B")]),
                    .list(items: [
                        ResolvedStoryListItem(entry: .text("List A"), nested: []),
                    ]),
                    .chaosTokenReference(face: .skull),
                    .divider,
                    .text("Read this"),
                    .cardReference(cardCode: cardCode, imageModifiers: [.smallImage]),
                    .tarotReference(arcana: "TheFool0"),
                    .chaosTokenMorph(from: .skull, target: .cultist),
                ])]
            ))],
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        let projection = gatheringProjection(includeAct: false, includeInvestigator: false)
        let renderedChoice = try #require(prompt.choices.first)
        #expect(
            prompt.displayTitle(for: renderedChoice, in: projection)
                == "Heading text; Modified text; Column A; Column B; List A; Chaos token Skull; Read this; Lita Chantler; Tarot TheFool0; Chaos token Skull to Cultist"
        )
    }
}

// swiftlint:enable line_length
