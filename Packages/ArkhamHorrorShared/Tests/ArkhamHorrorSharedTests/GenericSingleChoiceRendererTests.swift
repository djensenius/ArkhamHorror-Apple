// swiftlint:disable file_length function_body_length type_body_length line_length large_tuple
@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Generic single-choice prompt renderer")
struct GenericSingleChoiceRendererTests {
    @Test("Resolver renders every v2 choice kind with concrete text")
    func resolverRendersEveryChoiceKind() throws {
        try assertFixtureCoverage()
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
            .costLabel: "free",
            .drawCard: "Draw a card",
            .drawEncounterCard: "Draw encounter card",
            .effectActionButton: "Effect tooltip",
            .endTurn: "End turn",
            .engage: "Engage Ghoul Priest",
            .evade: "Evade Ghoul Priest",
            .fight: "Fight Ghoul Priest",
            .gainResource: "Gain a resource",
            .info: "Info title",
            .invalidLabel: "Invalid option",
            .investigate: "Investigate Study",
            .keyLabel: "Red Key",
            .localizedLabel: "Basic option",
            .move: "Move to Study (1 action)",
            .opaque: "OpaqueTag",
            .resolveForcedAbility: "Resolve forced ability at Study (free)",
            .skillLabel: "Willpower",
            .skipTriggers: "Skip triggers",
            .startSkillTest: "Start skill test",
            .tarotLabel: "The Fool0",
            .useAbility: "Use Machete ability 2 (1 resource)",
            .wizardChoice: "Wizard option",
        ]
        #expect(rendered == expected)
        #expect(subtitles[.invalidLabel] == "Not selectable")
        #expect(subtitles[.localizedLabel] == nil)
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
            .init(sourceIndex: 22, kind: .info, selectable: false, flavorText: .init(title: "Info title", body: [])),
            .init(sourceIndex: 23, kind: .invalidLabel, selectable: false, label: label("$invalid")),
            .init(sourceIndex: 24, kind: .investigate, entity: .init(kind: .location, id: location)),
            .init(sourceIndex: 25, kind: .keyLabel, key: .object(["tag": .string("RedKey")])),
            .init(sourceIndex: 26, kind: .localizedLabel, label: label("$basic")),
            .init(sourceIndex: 27, kind: .move, entity: .init(kind: .location, id: location), ability: ability(index: 1), cost: .action(1)),
            .init(sourceIndex: 28, kind: .opaque, uiTag: "OpaqueTag"),
            .init(sourceIndex: 29, kind: .resolveForcedAbility, entity: .init(kind: .location, id: location), ability: ability(index: 1, type: .forced), cost: .free),
            .init(sourceIndex: 30, kind: .skillLabel, skillType: .willpower),
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
            ("question-generic-choose-n", "question-presentation-generic-choose-n", 1),
            ("question-generic-choose-some", "question-presentation-generic-choose-some", 0),
            ("question-generic-choose-up-to-n", "question-presentation-generic-choose-up-to-n", 0),
            ("question-generic-one-from-each", "question-presentation-generic-one-from-each", 1),
            ("question-generic-one-at-a-time-auto", "question-presentation-generic-one-at-a-time-auto", 1),
            ("question-generic-read", "question-presentation-generic-read", 0),
            ("question-generic-wrapped", "question-presentation-generic-wrapped", 0),
            ("question-generic-skill-label", "question-presentation-generic-skill-label", 0),
        ]
        for fixtureCase in fixtureCases {
            try await assertFixturePromptSends(
                rawFixture: fixtureCase.raw,
                presentationFixture: fixtureCase.presentation,
                choiceIndex: fixtureCase.choice
            )
        }

        try await assertRepresentativePromptSends(
            name: "playerWindowChooseOne",
            rawQuestion: rawDirectQuestion(tag: "PlayerWindowChooseOne", count: 32),
            choiceIndex: 0
        )
        try await assertRepresentativePromptSends(
            name: "windowChooseOne",
            rawQuestion: rawDirectQuestion(tag: "WindowChooseOne", count: 32),
            choiceIndex: 0
        )
        try await assertRepresentativePromptSends(
            name: "chooseSome1",
            rawQuestion: .object([
                "tag": .string("ChooseSome1"),
                "label": .string("$done"),
                "choices": .array([rawLabel("$a"), rawLabel("$done")]),
            ]),
            choiceIndex: 0
        )
        try await assertRepresentativePromptSends(
            name: "chooseOneWizard",
            rawQuestion: .object([
                "tag": .string("ChooseOneWizard"),
                "flavorText": .object(["title": .null, "body": .array([])]),
                "wizardChoices": .array([rawLabel("$wizard")]),
                "confirmLabel": .string("$confirm"),
                "backLabel": .string("$back"),
            ]),
            choiceIndex: 0
        )
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

    private func rawLabel(_ label: String) -> JSONValue {
        .object([
            "tag": .string("Label"),
            "label": .string(label),
            "messages": .array([]),
        ])
    }
}

private enum GenericRendererTestError: Error {
    case unexpectedFixture
}

// swiftlint:enable file_length function_body_length type_body_length line_length large_tuple
