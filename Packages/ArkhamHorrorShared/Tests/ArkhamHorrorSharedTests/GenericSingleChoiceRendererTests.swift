// swiftlint:disable file_length function_body_length type_body_length line_length large_tuple
@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Generic single-choice prompt renderer")
struct GenericSingleChoiceRendererTests {
    @Test("Resolver renders every v2 choice kind with concrete text")
    func resolverRendersEveryChoiceKind() throws {
        try assertFixtureCoverage()
        try assertFixtureTitles()
        let projection = rendererProjection()
        let prompt = try syntheticAllKindsPrompt()
        var rendered: [QuestionPresentation.ChoiceKind: String] = [:]
        var subtitles: [QuestionPresentation.ChoiceKind: String] = [:]
        for choice in prompt.choices {
            let descriptor = try #require(prompt.semanticPresentation?.descriptor(
                forSourceIndex: choice.index
            ))
            let label = prompt.resolvedChoiceLabel(for: choice, in: projection)
            rendered[descriptor.kind] = label.title
            if let subtitle = label.subtitle {
                subtitles[descriptor.kind] = subtitle
            }
            #expect(!label.title.isEmpty, "\(descriptor.kind.rawValue)")
            #expect(label.title != "Update required", "\(descriptor.kind.rawValue)")
        }

        let expected: [QuestionPresentation.ChoiceKind: String] = [
            .advanceAct: "Advance act",
            .advanceAgenda: "Advance agenda",
            .applySkillTestResults: "Apply results",
            .assignDamage: "Assign damage to Roland Banks",
            .assignHorror: "Assign horror to Roland Banks",
            .auto: "Auto option",
            .auxiliaryComponentLabel: "Horror on Roland Banks",
            .cardPile: "Card pile (1 cards)",
            .chaosTokenGroupChoice: "Choose chaos token",
            .chaosTokenLabel: "Skull",
            .chooseTarget: "Choose Roland Banks",
            .componentLabel: "Damage on .45 Automatic",
            .connectionLabel: "Circle",
            .costLabel: "Free",
            .drawCard: "Draw a card",
            .drawEncounterCard: "Draw encounter card",
            .effectActionButton: "Effect tooltip",
            .endTurn: "End turn",
            .engage: "Engage Ghoul Priest",
            .evade: "Evade Ghoul Priest",
            .fight: "Fight Ghoul Priest",
            .gainResource: "Gain a resource",
            .info: "Localized info title",
            .invalidLabel: "Invalid option",
            .investigate: "Investigate Study",
            .keyLabel: "Red Key",
            .localizedLabel: "Basic option",
            .move: "Move to Study (1 action)",
            .opaque: "OpaqueTag",
            .resolveForcedAbility: "Resolve forced ability at Study (Free)",
            .skillLabel: "Use Willpower: Boost test",
            .skipTriggers: "Skip triggers",
            .startSkillTest: "Start skill test",
            .tarotLabel: "The Fool",
            .useAbility: "Use Machete ability 2 (1 resource)",
            .wizardChoice: "Wizard option",
        ]
        #expect(rendered == expected)
        #expect(subtitles[.info] == "Localized info body")
        #expect(subtitles[.invalidLabel] == "Not selectable")
        #expect(subtitles[.localizedLabel] == nil)

        let localized = try #require(prompt.choices.first { $0.index == 26 })
        let invalid = try #require(prompt.choices.first { $0.index == 23 })
        let info = try #require(prompt.choices.first { $0.index == 22 })
        #expect(prompt.accessibilityLabel(for: localized, in: projection) == "Basic option")
        #expect(!prompt.accessibilityLabel(for: localized, in: projection).hasPrefix("Choice "))
        #expect(prompt.accessibilityHint(for: invalid, in: projection) == "This choice is not selectable.")
        #expect(prompt.accessibilityHint(for: info, in: projection) == "This choice is not selectable.")
    }

    @Test("Choose-N prompts keep the count in the hint without duplicating the header")
    func chooseNPromptAvoidsDuplicateCountChrome() throws {
        let choices = [
            QuestionPresentation.Choice(sourceIndex: 0, kind: .localizedLabel, label: label("One")),
            QuestionPresentation.Choice(sourceIndex: 1, kind: .localizedLabel, label: label("Two")),
        ]
        let presentation = QuestionPresentation(
            protocolVersion: 2,
            questionVersion: 779,
            questionKind: .chooseN,
            choiceCount: choices.count,
            choices: choices,
            selection: .init(min: 2, max: 2)
        )
        let rawQuestion: JSONValue = .object([
            "tag": .string("ChooseN"),
            "amount": .number(.integer(2)),
            "choices": .array((0 ..< choices.count).map { index in
                .object([
                    "tag": .string("Label"),
                    "label": .string("$choice.\(index)"),
                    "messages": .array([]),
                ])
            }),
        ])
        let binding = try presentation.bind(to: rawQuestion, expectedQuestionVersion: 779)
        let prompt = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 779,
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

        #expect(prompt.headerTitle(in: rendererProjection()) == "Choose choices")
        #expect(prompt.questionHint() == "Choose 2")
    }

    @Test("Tarot arcana titles use display names without appended ordinals")
    func tarotArcanaDisplayNameStripsOrdinal() throws {
        let prompt = try singleChoicePrompt(
            choice: .init(
                sourceIndex: 0,
                kind: .tarotLabel,
                tarotCard: .init(facing: .upright, arcana: "TheHighPriestessII")
            )
        )
        let choice = try #require(prompt.choices.first)
        #expect(prompt.displayTitle(for: choice, in: rendererProjection()) == "The High Priestess")
    }

    @MainActor
    @Test("Generic prompt choices expose meaningful accessibility and prompt-list focus")
    func genericPromptAccessibilityAndFocusUsePromptCoordinator() throws {
        let prompt = try inlineLabelPrompt()
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let enabledChoice = try #require(prompt.choices.first { $0.index == 0 })
        let disabledChoice = try #require(prompt.choices.first { $0.index == 1 })

        #expect(prompt.accessibilityLabel(for: enabledChoice, in: projection) == "Real option")
        #expect(prompt.accessibilityLabel(for: disabledChoice, in: projection) == "Disabled option")
        #expect(prompt.accessibilityHint(for: disabledChoice, in: projection) == "This choice is not selectable.")

        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onChoice: { submitted.append($0) }
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0])
        #expect(!controller.activatePromptChoice(1))
        #expect(submitted == [0])
    }

    private func assertFixtureCoverage() throws {
        var kinds: Set<QuestionPresentation.ChoiceKind> = []
        let representatives = try representativePresentations()
        for entry in representatives {
            kinds.formUnion(entry.presentation.choices.map(\.kind))
        }
        let fixtureNames = [
            "question-presentation-generic-cost-ability-window",
            "question-presentation-generic-one-at-a-time-auto",
            "question-presentation-generic-read",
            "question-presentation-generic-wrapped",
            "question-presentation-encounter-deck-draw",
            "question-presentation-gathering-act-advance",
            "question-presentation-gathering-attic-horror-assignment",
            "question-presentation-gathering-cellar-damage-assignment",
            "question-presentation-gathering-movement",
            "question-presentation-gathering-cellar-entry-forced",
        ]
        for name in fixtureNames {
            try kinds.formUnion(presentationFixture(name).choices.map(\.kind))
        }
        // No vendored 0.1.47 fixture currently exercises advanceAgenda; keep the
        // explicit synthetic resolver assertion below as coverage for that final kind.
        let missing = Set(QuestionPresentation.ChoiceKind.allRendererCases)
            .subtracting(kinds)
        #expect(missing == [.advanceAgenda])
    }

    private func assertFixtureTitles() throws {
        let projection = rendererProjection()
        let fixtureCases: [(
            raw: String,
            presentation: String,
            labels: [Int: BasicChoiceLabelResolution],
            titles: [Int: String]
        )] = [
            (
                "question-generic-one-at-a-time-auto",
                "question-presentation-generic-one-at-a-time-auto",
                [
                    0: .resolved("Auto fixture"),
                    1: .resolved("First fixture"),
                    2: .resolved("Second fixture"),
                ],
                [0: "Auto fixture", 1: "First fixture", 2: "Second fixture"]
            ),
            (
                "question-encounter-deck-draw",
                "question-presentation-encounter-deck-draw",
                [:],
                [0: "Draw encounter card"]
            ),
            (
                "question-generic-skill-label",
                "question-presentation-generic-skill-label",
                [:],
                [0: "Willpower"]
            ),
        ]
        for fixtureCase in fixtureCases {
            let prompt = try fixturePrompt(
                rawFixture: fixtureCase.raw,
                presentationFixture: fixtureCase.presentation,
                choiceLabelResolutions: fixtureCase.labels
            )
            let rendered = Dictionary(uniqueKeysWithValues: prompt.choices.map {
                ($0.index, prompt.displayTitle(for: $0, in: projection))
            })
            #expect(rendered == fixtureCase.titles, "\(fixtureCase.presentation)")
        }
    }

    private func fixturePrompt(
        rawFixture: String,
        presentationFixture fixtureName: String,
        choiceLabelResolutions: [Int: BasicChoiceLabelResolution]
    ) throws -> BasicChoicePromptPresentation {
        let raw = try ContractJSON.decode(JSONValue.self, from: fixture(rawFixture))
        let presentation = try presentationFixture(fixtureName)
        let binding = try presentation.bind(
            to: raw,
            expectedQuestionVersion: presentation.questionVersion
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: presentation.questionVersion,
                rawQuestion: raw,
                questionPresentation: presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: BasicChoiceParser.parseQuestion(raw),
            semanticPresentation: binding,
            semanticLocaleIdentifier: "en",
            cardCatalog: nil,
            choiceLabelResolutions: choiceLabelResolutions,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private func syntheticAllKindsPrompt() throws -> BasicChoicePromptPresentation {
        let choices = allKindChoices()
        let presentation = QuestionPresentation(
            protocolVersion: 2,
            questionVersion: 777,
            questionKind: .chooseOne,
            choiceCount: choices.count,
            choices: choices
        )
        let rawQuestion = rawQuestion(tag: "ChooseOne", count: choices.count)
        let binding = try presentation.bind(to: rawQuestion, expectedQuestionVersion: 777)
        return try BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 777,
                rawQuestion: rawQuestion,
                questionPresentation: presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: BasicChoiceParser.parseQuestion(rawQuestion),
            semanticPresentation: binding,
            semanticLocaleIdentifier: "en",
            cardCatalog: CardCatalogSnapshot(namesByCode: [
                CardCode("c01001"): CardName(title: "Roland Banks", subtitle: nil),
                CardCode("c01111"): CardName(title: "Machete", subtitle: nil),
                CardCode("c01112"): CardName(title: "The Barrier", subtitle: nil),
            ]),
            choiceLabelResolutions: labelResolutions(),
            choiceFlavorResolutions: choiceFlavorResolutions(),
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private func singleChoicePrompt(
        choice: QuestionPresentation.Choice
    ) throws -> BasicChoicePromptPresentation {
        let presentation = QuestionPresentation(
            protocolVersion: 2,
            questionVersion: 780,
            questionKind: .chooseOne,
            choiceCount: 1,
            choices: [choice]
        )
        let rawQuestion = rawQuestion(tag: "ChooseOne", count: 1)
        let binding = try presentation.bind(to: rawQuestion, expectedQuestionVersion: 780)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 780,
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
    }

    private func inlineLabelPrompt() throws -> BasicChoicePromptPresentation {
        let choices = [
            QuestionPresentation.Choice(
                sourceIndex: 0,
                kind: .localizedLabel,
                label: label("Real option")
            ),
            QuestionPresentation.Choice(
                sourceIndex: 1,
                kind: .localizedLabel,
                selectable: false,
                label: label("Disabled option")
            ),
        ]
        let presentation = QuestionPresentation(
            protocolVersion: 2,
            questionVersion: 778,
            questionKind: .chooseOne,
            choiceCount: choices.count,
            choices: choices
        )
        let rawQuestion = rawQuestion(tag: "ChooseOne", count: choices.count)
        let binding = try presentation.bind(to: rawQuestion, expectedQuestionVersion: 778)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 778,
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
    }

    private func allKindChoices() -> [QuestionPresentation.Choice] {
        let location = "00000000-0000-0000-0000-00000000004a"
        let enemy = "00000000-0000-0000-0000-000000000047"
        let asset = "00000000-0000-0000-0000-000000000048"
        return [
            .init(sourceIndex: 0, kind: .advanceAct, entity: .init(kind: .act, id: "c01112")),
            .init(sourceIndex: 1, kind: .advanceAgenda, entity: .init(kind: .agenda, id: "c01113")),
            .init(sourceIndex: 2, kind: .applySkillTestResults),
            .init(sourceIndex: 3, kind: .assignDamage, entity: .init(kind: .investigator, id: "c01001")),
            .init(sourceIndex: 4, kind: .assignHorror, entity: .init(kind: .investigator, id: "c01001")),
            .init(sourceIndex: 5, kind: .auto, label: label("$auto")),
            .init(sourceIndex: 6, kind: .auxiliaryComponentLabel, entity: .init(kind: .investigator, id: "c01001"), component: .investigator(investigatorID: "c01001", tokenType: .horror)),
            .init(sourceIndex: 7, kind: .cardPile, cards: [.init(cardID: "card-a", cardOwner: "c01001")]),
            .init(sourceIndex: 8, kind: .chaosTokenGroupChoice, actorID: "c01001"),
            .init(sourceIndex: 9, kind: .chaosTokenLabel, face: "Skull"),
            .init(sourceIndex: 10, kind: .chooseTarget, entity: .init(kind: .cardCode, id: "c01001")),
            .init(sourceIndex: 11, kind: .componentLabel, entity: .init(kind: .asset, id: asset), component: .asset(assetID: asset, tokenType: .damage)),
            .init(sourceIndex: 12, kind: .connectionLabel, connection: .circle),
            .init(sourceIndex: 13, kind: .costLabel, cost: .free),
            .init(sourceIndex: 14, kind: .drawCard, actorID: "c01001"),
            .init(sourceIndex: 15, kind: .drawEncounterCard, actorID: "c01001"),
            .init(sourceIndex: 16, kind: .effectActionButton, entity: .init(kind: .effect, id: "effect"), tooltip: "Effect tooltip"),
            .init(sourceIndex: 17, kind: .endTurn, actorID: "c01001"),
            .init(sourceIndex: 18, kind: .engage, entity: .init(kind: .enemy, id: enemy)),
            .init(sourceIndex: 19, kind: .evade, entity: .init(kind: .enemy, id: enemy)),
            .init(sourceIndex: 20, kind: .fight, entity: .init(kind: .enemy, id: enemy)),
            .init(sourceIndex: 21, kind: .gainResource, actorID: "c01001"),
            .init(
                sourceIndex: 22,
                kind: .info,
                selectable: false,
                flavorText: .init(title: "$info.title", body: [.object([
                    "tag": .string("I18nEntry"),
                    "key": .string("info.body"),
                    "variables": .object([:]),
                ])])
            ),
            .init(sourceIndex: 23, kind: .invalidLabel, selectable: false, label: label("$invalid")),
            .init(sourceIndex: 24, kind: .investigate, entity: .init(kind: .location, id: location)),
            .init(sourceIndex: 25, kind: .keyLabel, key: .object(["tag": .string("RedKey")])),
            .init(sourceIndex: 26, kind: .localizedLabel, label: label("$basic")),
            .init(sourceIndex: 27, kind: .move, entity: .init(kind: .location, id: location), ability: ability(index: 1), cost: .action(1)),
            .init(sourceIndex: 28, kind: .opaque, uiTag: "OpaqueTag"),
            .init(sourceIndex: 29, kind: .resolveForcedAbility, entity: .init(kind: .location, id: location), ability: ability(index: 1, type: .forced), cost: .free),
            .init(sourceIndex: 30, kind: .skillLabel, label: label("Boost test"), skillType: .willpower),
            .init(sourceIndex: 31, kind: .skipTriggers, actorID: "c01001"),
            .init(sourceIndex: 32, kind: .startSkillTest, actorID: "c01001"),
            .init(sourceIndex: 33, kind: .tarotLabel, tarotCard: .init(facing: .upright, arcana: "TheFool0")),
            .init(sourceIndex: 34, kind: .useAbility, actorID: "c01001", ability: ability(index: 2), cost: .resource(1)),
            .init(sourceIndex: 35, kind: .wizardChoice, label: label("$wizard")),
        ]
    }

    private func ability(
        index: Int,
        type: QuestionPresentation.AbilityType = .action
    ) -> QuestionPresentation.Ability {
        .init(
            cardCode: "c01111",
            index: index,
            type: type,
            actions: [.investigate],
            canBeCancelled: false
        )
    }

    private func label(_ text: String) -> QuestionPresentation.Label {
        .init(kind: .embeddedI18n, text: text)
    }

    private func labelResolutions() -> [Int: BasicChoiceLabelResolution] {
        [
            5: .resolved("Auto option"),
            23: .resolved("Invalid option"),
            26: .resolved("Basic option"),
            35: .resolved("Wizard option"),
        ]
    }

    private func choiceFlavorResolutions() -> [Int: StoryResolution] {
        [
            22: .resolved(ResolvedStory(
                title: "Localized info title",
                body: [.nodes([.text("Localized info body")])]
            )),
        ]
    }

    private func rendererProjection() -> BoardProjection {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let locationID = BoardTestFixtures.locationID("00000000004a")
        let enemyID = BoardTestFixtures.enemyID("000000000047")
        let assetID = BoardTestFixtures.assetID("000000000048")
        let actID = BoardTestFixtures.actID("c01112")
        let agendaID = BoardTestFixtures.agendaID("c01113")
        let snapshot = BoardTestFixtures.snapshot(
            locations: [(
                locationID,
                .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: locationID,
                    label: "Study",
                    investigators: [investigatorID],
                    enemies: [enemyID],
                    assets: [assetID]
                ))
            )],
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    name: CardName(title: "Roland Banks", subtitle: nil),
                    assets: [assetID]
                ),
            ],
            acts: [actID: BoardTestFixtures.act(id: actID)],
            agendas: [agendaID: BoardTestFixtures.agenda(id: agendaID)],
            enemyValues: [
                enemyID: .object([
                    "id": .string(enemyID.codingKey.stringValue),
                    "label": .string("Ghoul Priest"),
                ]),
            ],
            assetValues: [
                assetID: .object([
                    "id": .string(assetID.codingKey.stringValue),
                    "label": .string(".45 Automatic"),
                    "cardCode": .string("c01016"),
                ]),
            ]
        )
        return BoardProjectionBuilder.makeProjection(from: snapshot)
    }

    private func rawQuestion(tag: String, count: Int) -> JSONValue {
        .object([
            "tag": .string(tag),
            "choices": .array((0 ..< count).map { index in
                .object([
                    "tag": .string("Label"),
                    "label": .string("$choice.\(index)"),
                    "messages": .array([]),
                ])
            }),
        ])
    }

    private func representativePresentations() throws -> [RepresentativePresentation] {
        struct Representatives: Decodable {
            let presentations: [RepresentativePresentation]
        }
        return try ContractJSON.decode(
            Representatives.self,
            from: fixture("question-presentation-representatives")
        ).presentations
    }

    private func presentationFixture(_ name: String) throws -> QuestionPresentation {
        try ContractJSON.decode(QuestionPresentation.self, from: fixture(name))
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }
}

private struct RepresentativePresentation: Decodable {
    let name: String
    let presentation: QuestionPresentation
}

private extension QuestionPresentation.ChoiceKind {
    static let allRendererCases: [Self] = [
        .advanceAct,
        .advanceAgenda,
        .applySkillTestResults,
        .assignDamage,
        .assignHorror,
        .auto,
        .auxiliaryComponentLabel,
        .cardPile,
        .chaosTokenGroupChoice,
        .chaosTokenLabel,
        .chooseTarget,
        .componentLabel,
        .connectionLabel,
        .costLabel,
        .drawCard,
        .drawEncounterCard,
        .effectActionButton,
        .endTurn,
        .engage,
        .evade,
        .fight,
        .gainResource,
        .info,
        .invalidLabel,
        .investigate,
        .keyLabel,
        .localizedLabel,
        .move,
        .opaque,
        .resolveForcedAbility,
        .skillLabel,
        .skipTriggers,
        .startSkillTest,
        .tarotLabel,
        .useAbility,
        .wizardChoice,
    ]
}

extension AppModelLiveGameTests {
    @Test("Generic single-choice fixture prompts render and send exact Answer envelopes")
    func genericSingleChoiceFixturesSendExactBasicChoiceAnswer() async throws {
        let fixtureCases: [(raw: String, presentation: String, choice: Int)] = [
            ("question-generic-cost-ability-window", "question-presentation-generic-cost-ability-window", 0),
            ("question-generic-skill-label", "question-presentation-generic-skill-label", 0),
        ]
        for fixtureCase in fixtureCases {
            try await assertFixturePromptSends(
                rawFixture: fixtureCase.raw,
                presentationFixture: fixtureCase.presentation,
                choiceIndex: fixtureCase.choice
            )
        }
    }

    private func assertFixturePromptSends(
        rawFixture: String,
        presentationFixture: String,
        choiceIndex: Int
    ) async throws {
        let presentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: fixtureData(named: presentationFixture)
        )
        let envelope = try semanticEnvelope(
            rawFixture: rawFixture,
            presentationFixture: presentationFixture,
            questionVersion: presentation.questionVersion
        )
        try await assertEnvelopeSends(
            envelope,
            choiceIndex: choiceIndex,
            note: presentationFixture
        )
    }

    private func assertRepresentativePromptSends(
        name: String,
        rawQuestion: JSONValue,
        choiceIndex: Int
    ) async throws {
        let representative = try representativePresentation(named: name)
        let envelope = try envelope(rawQuestion: rawQuestion, presentation: representative.presentation)
        try await assertEnvelopeSends(envelope, choiceIndex: choiceIndex, note: name)
    }

    private func assertEnvelopeSends(
        _ envelope: GetGameEnvelope,
        choiceIndex: Int,
        note: String
    ) async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID), "\(note)")
        #expect(prompt.isRenderableQuestion, "\(note)")
        #expect(prompt.canSubmit, "\(note)")
        let projection = try #require(model.liveGameState(for: gameID).lastKnownProjection)
        let choice = try #require(prompt.choices.first { $0.index == choiceIndex })
        #expect(prompt.isChoiceActionable(choice, in: projection), "\(note)")
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: choiceIndex)
                == .sentAwaitingSnapshot,
            "\(note)"
        )
        let expected = try ContractJSON.encode(BasicChoiceAnswer(
            choice: choiceIndex,
            playerID: #require(envelope.playerID),
            questionVersion: envelope.game.scenarioSteps
        ))
        #expect(await connection.sentData == [expected], "\(note)")
    }

    private func envelope(
        rawQuestion: JSONValue,
        presentation: QuestionPresentation
    ) throws -> GetGameEnvelope {
        let envelope = try ContractJSON.decode(JSONValue.self, from: fixtureData(named: "get-game"))
        guard case var .object(root) = envelope,
              case var .object(game)? = root["game"],
              case let .string(playerID)? = root["playerId"]
        else { throw GenericRendererTestError.unexpectedFixture }
        game["question"] = .object([playerID: rawQuestion])
        game["questionPresentation"] = try .object([
            playerID: ContractJSON.decode(
                JSONValue.self,
                from: ContractJSON.encode(presentation)
            ),
        ])
        game["scenarioSteps"] = .number(.integer(Int64(presentation.questionVersion)))
        root["game"] = .object(game)
        let encoded: JSONValue = .object(root)
        return try ContractJSON.decode(GetGameEnvelope.self, from: ContractJSON.encode(encoded))
    }

    private func representativePresentation(named name: String) throws -> RepresentativePresentation {
        struct Representatives: Decodable {
            let presentations: [RepresentativePresentation]
        }
        let representatives = try ContractJSON.decode(
            Representatives.self,
            from: fixtureData(named: "question-presentation-representatives")
        )
        return try #require(representatives.presentations.first { $0.name == name })
    }

    private func rawDirectQuestion(tag: String, count: Int) -> JSONValue {
        .object([
            "tag": .string(tag),
            "choices": .array((0 ..< count).map { rawLabel("$choice.\($0)") }),
        ])
    }

    private func rawChooseSome1Question() -> JSONValue {
        // Arkham/Question.hs:196 declares ChooseSome1's raw label/choices fields;
        // Arkham/Question/Presentation.hs:463-470 adds selection and completionLabel.
        .object([
            "tag": .string("ChooseSome1"),
            "label": .string("$done"),
            "choices": .array([rawLabel("$a"), rawDone("$done")]),
        ])
    }

    private func rawChooseOneWizardQuestion() -> JSONValue {
        // Arkham/Question.hs:156-159 and 234-238 define WizardChoice and
        // ChooseOneWizard; Arkham/Question/Presentation.hs:528-533 binds
        // wizardChoices to source-indexed wizardChoice descriptors.
        .object([
            "tag": .string("ChooseOneWizard"),
            "flavorText": flavorText(),
            "wizardChoices": .array([rawWizardChoice("$wizard")]),
            "confirmLabel": .string("$confirm"),
            "backLabel": .string("$back"),
        ])
    }

    private func rawLabel(_ label: String) -> JSONValue {
        .object([
            "tag": .string("Label"),
            "label": .string(label),
            "messages": .array([]),
        ])
    }

    private func rawDone(_ label: String) -> JSONValue {
        .object([
            "tag": .string("Done"),
            "label": .string(label),
        ])
    }

    private func rawWizardChoice(_ label: String) -> JSONValue {
        .object([
            "label": .string(label),
            "flavorText": flavorText(),
            "messages": .array([]),
        ])
    }

    private func flavorText() -> JSONValue {
        .object(["title": .null, "body": .array([])])
    }
}

private enum GenericRendererTestError: Error {
    case unexpectedFixture
}

// swiftlint:enable file_length function_body_length type_body_length line_length large_tuple
