@testable import ArkhamHorrorShared
import Foundation
import Testing

private struct PickDestinyPreferredLanguages: PreferredLanguagesProviding {
    let preferredLanguages: [String]
}

// swiftlint:disable file_length
@MainActor
@Suite("Pick Destiny prompt")
// swiftlint:disable:next type_body_length
struct PickDestinyPromptTests {
    @Test("Locale catalog resolves title, instructions, done, tarot and scoped destiny names")
    func localeCatalogResolutionUsesWebKeyOrder() async throws {
        let model = try await Self.appModelWithCatalog(entries: [
            "pickDestiny.title": "Pick Destiny",
            "pickDestiny.instructions": "Reverse half the tarot cards.",
            "label.done": "Done",
            "theCircleUndone.destiny.theWitchingHour": "Scoped Witching Hour",
            "destiny.theWitchingHour": "Global Witching Hour",
            "destiny.atDeath'sDoorstep": "At Death's Doorstep",
            "tarot.TemperanceXIV": "Temperance • XIV",
            "tarot.JusticeXI": "Justice • XI",
        ])
        let presentation = Self.questionPresentation(drawings: [
            Self.drawing(scenario: "theWitchingHour", arcana: "TemperanceXIV"),
            Self.drawing(scenario: "atDeath'sDoorstep", arcana: "JusticeXI"),
        ])

        let resolved = model.pickDestinyPromptPresentation(
            for: presentation,
            campaignScope: "theCircleUndone"
        )
        let prompt = try #require(resolved?.presentation)

        #expect(prompt.title == "Pick Destiny")
        #expect(prompt.instructions == "Reverse half the tarot cards.")
        #expect(prompt.doneLabel == "Done")
        #expect(prompt.rows.map(\.scenarioTitle) == [
            "Scoped Witching Hour",
            "At Death's Doorstep",
        ])
        #expect(prompt.rows.map(\.tarotTitle) == ["Temperance • XIV", "Justice • XI"])
    }

    @Test("Missing catalog labels keep the Pick Destiny prompt unavailable")
    func missingCatalogLabelDoesNotExposeRawKeys() async throws {
        let model = try await Self.appModelWithCatalog(entries: [
            "pickDestiny.title": "Pick Destiny",
            "pickDestiny.instructions": "Reverse half the tarot cards.",
            "label.done": "Done",
            "destiny.theWitchingHour": "The Witching Hour",
        ])
        let presentation = Self.questionPresentation(drawings: [
            Self.drawing(scenario: "theWitchingHour", arcana: "TemperanceXIV"),
        ])

        let resolved = model.pickDestinyPromptPresentation(
            for: presentation,
            campaignScope: "theCircleUndone"
        )

        #expect(resolved?.presentation == nil)
        #expect(resolved?.unavailableReason == .missingKey)
    }

    @Test("Apple-only Pick Destiny strings exist in English and German bundles")
    func appleOnlyStringsResolveFromModuleBundle() throws {
        let keys = [
            "pickDestiny.facing.upright",
            "pickDestiny.facing.reversed",
            "pickDestiny.progress",
            "pickDestiny.row.flip.hint",
            "pickDestiny.submit.hint",
            "pickDestiny.submit.disabled.count",
            "pickDestiny.submit.disabled.readOnly",
            "pickDestiny.names.loading",
            "pickDestiny.names.unavailable",
        ]
        #expect(try localizedModuleString(
            "pickDestiny.facing.upright",
            fallback: "__missing__",
            locale: "en"
        ) == "Upright")
        for locale in ["en", "de"] {
            let strings = try localizableStrings(locale: locale)
            for key in keys {
                #expect(strings.contains("\"\(key)\" ="))
            }
        }
    }

    @Test("PickDestinyAnswer encodes the exact web/server JSON shape")
    func pickDestinyAnswerWireShape() throws {
        let selected = [
            Self.drawing(scenario: "theWitchingHour", arcana: "TemperanceXIV", facing: .reversed),
            Self.drawing(scenario: "atDeath'sDoorstep", arcana: "JusticeXI", facing: .upright),
        ]
        let payload = try ContractJSON.encode(PickDestinyAnswer(contents: selected))
        let object = try ContractJSON.decode(JSONValue.self, from: payload)
        let wire = try #require(String(data: payload, encoding: .utf8))

        #expect(object == .object([
            "tag": .string("PickDestinyAnswer"),
            "contents": .array([
                .object([
                    "scenario": .string("theWitchingHour"),
                    "tarot": .object([
                        "facing": .string("Reversed"),
                        "arcana": .string("TemperanceXIV"),
                    ]),
                ]),
                .object([
                    "scenario": .string("atDeath'sDoorstep"),
                    "tarot": .object([
                        "facing": .string("Upright"),
                        "arcana": .string("JusticeXI"),
                    ]),
                ]),
            ]),
        ]))
        let expectedWire = "{\"contents\":[{\"scenario\":\"theWitchingHour\","
            + "\"tarot\":{\"arcana\":\"TemperanceXIV\",\"facing\":\"Reversed\"}},"
            + "{\"scenario\":\"atDeath'sDoorstep\",\"tarot\":{\"arcana\":\"JusticeXI\","
            + "\"facing\":\"Upright\"}}],\"tag\":\"PickDestinyAnswer\"}"
        #expect(wire == expectedWire)
    }

    @Test("Odd Pick Destiny counts round the required reversed cards up")
    func oddCountRoundsRequiredReversedUp() {
        let published = [
            Self.drawing(scenario: "one", arcana: "TemperanceXIV"),
            Self.drawing(scenario: "two", arcana: "JusticeXI"),
            Self.drawing(scenario: "three", arcana: "TheHermitIX"),
        ]
        let oneReversed = [
            Self.drawing(scenario: "one", arcana: "TemperanceXIV", facing: .reversed),
            Self.drawing(scenario: "two", arcana: "JusticeXI"),
            Self.drawing(scenario: "three", arcana: "TheHermitIX"),
        ]
        let twoReversed = [
            Self.drawing(scenario: "one", arcana: "TemperanceXIV", facing: .reversed),
            Self.drawing(scenario: "two", arcana: "JusticeXI", facing: .reversed),
            Self.drawing(scenario: "three", arcana: "TheHermitIX"),
        ]

        #expect(PickDestinySelectionRules.requiredReversedCount(for: published.count) == 2)
        #expect(!PickDestinySelectionRules.canSubmit(oneReversed, published: published))
        #expect(PickDestinySelectionRules.canSubmit(twoReversed, published: published))
    }

    @Test("Board command controller rejects Pick Destiny count and sequence violations")
    func boardCommandControllerGuardsPickDestinySubmission() throws {
        let ownerID = BoardTestFixtures.playerID()
        let published = [
            Self.drawing(scenario: "theWitchingHour", arcana: "TemperanceXIV"),
            Self.drawing(scenario: "atDeath'sDoorstep", arcana: "JusticeXI"),
        ]
        let prompt = try Self.promptPresentation(ownerID: ownerID, drawings: published)
        let projection = Self.projection(ownerID: ownerID, prompt: prompt)
        var submitted: [[QuestionPresentation.DestinyDrawing]] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onPickDestiny: { submitted.append($0) }
        )

        #expect(!controller.activatePickDestinySubmit(published))
        #expect(!controller.activatePickDestinySubmit([
            Self.drawing(scenario: "atDeath'sDoorstep", arcana: "JusticeXI", facing: .reversed),
            Self.drawing(scenario: "theWitchingHour", arcana: "TemperanceXIV"),
        ]))
        let valid = [
            Self.drawing(scenario: "theWitchingHour", arcana: "TemperanceXIV", facing: .reversed),
            Self.drawing(scenario: "atDeath'sDoorstep", arcana: "JusticeXI"),
        ]
        #expect(controller.activatePickDestinySubmit(valid))
        #expect(submitted == [valid])
    }

    @Test("Board focus graph exposes Pick Destiny rows and submit through controller actions")
    func boardFocusGraphAndControllerActivatePickDestinyControls() throws {
        let ownerID = BoardTestFixtures.playerID()
        let published = [
            Self.drawing(scenario: "theWitchingHour", arcana: "TemperanceXIV"),
            Self.drawing(scenario: "atDeath'sDoorstep", arcana: "JusticeXI"),
        ]
        let prompt = try Self.promptPresentation(
            ownerID: ownerID,
            drawings: published,
            includeResolvedPrompt: true
        )
        let projection = Self.projection(ownerID: ownerID, prompt: prompt)
        var submitted: [[QuestionPresentation.DestinyDrawing]] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onPickDestiny: { submitted.append($0) }
        )
        let firstRow = BoardFocusID.promptPickDestinyRow(0)
        let secondRow = BoardFocusID.promptPickDestinyRow(1)

        #expect(controller.coordinator.graph.contains(firstRow))
        #expect(controller.coordinator.graph.contains(secondRow))
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptPickDestinySubmit))
        #expect(controller.coordinator.graph.zoneEntryPoints[BoardFocusZone.prompt] == firstRow)
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == firstRow)
        #expect(controller.handle(.command(.focusMove(.down))))
        #expect(controller.coordinator.currentFocus == secondRow)
        #expect(controller.handle(.command(.focusMove(.down))))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptPickDestinySubmit)
        #expect(controller.handle(focusID: firstRow, .command(.primaryAction)))
        let selected = [
            Self.drawing(scenario: "theWitchingHour", arcana: "TemperanceXIV", facing: .reversed),
            Self.drawing(scenario: "atDeath'sDoorstep", arcana: "JusticeXI"),
        ]
        #expect(controller.pickDestinyDrawings == selected)
        #expect(controller.handle(
            focusID: BoardFocusID.promptPickDestinySubmit,
            .command(.primaryAction)
        ))
        #expect(submitted == [selected])
    }

    @Test("AppModel send fence rejects illegal Pick Destiny answers before transport")
    func appModelRejectsIllegalPickDestinyBeforeSend() async throws {
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: ScriptedGameLifecycleService()
        )
        model.sessionState = .signedIn(
            profile: .hosted,
            compatibility: .modern(capabilities: []),
            user: .sample
        )
        let ownerID = BoardTestFixtures.playerID()
        let gameID = BoardTestFixtures.gameID()
        let published = [
            Self.drawing(scenario: "theWitchingHour", arcana: "TemperanceXIV"),
            Self.drawing(scenario: "atDeath'sDoorstep", arcana: "JusticeXI"),
        ]
        let payload = try Self.payload(drawings: published)
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            questions: [ownerID: payload]
        ))
        let connection = FakeGameSocketConnection()
        Self.installLivePrompt(
            model: model,
            gameID: gameID,
            ownerID: ownerID,
            projection: projection,
            connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))

        let illegal = [
            Self.drawing(scenario: "theWitchingHour", arcana: "TemperanceXIV", facing: .reversed),
            Self.drawing(scenario: "otherScenario", arcana: "JusticeXI"),
        ]

        #expect(await model.submitPickDestinyAnswer(
            prompt.identity,
            drawings: illegal
        ) == .unsupportedChoice)
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Mismatched Pick Destiny envelope is unsendable")
    func appModelRejectsMismatchedSemanticPickDestinyBeforeSend() async throws {
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: ScriptedGameLifecycleService()
        )
        model.sessionState = .signedIn(
            profile: .hosted,
            compatibility: .modern(capabilities: []),
            user: .sample
        )
        let ownerID = BoardTestFixtures.playerID()
        let gameID = BoardTestFixtures.gameID()
        let raw = [
            Self.drawing(scenario: "theWitchingHour", arcana: "TemperanceXIV"),
            Self.drawing(scenario: "atDeath'sDoorstep", arcana: "JusticeXI"),
        ]
        let mismatchedEnvelope = [
            Self.drawing(scenario: "theWitchingHour", arcana: "TemperanceXIV"),
            Self.drawing(scenario: "theSecretName", arcana: "JusticeXI"),
        ]
        let payload = try Self.payload(
            rawDrawings: raw,
            presentationDrawings: mismatchedEnvelope
        )
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            questions: [ownerID: payload]
        ))
        let connection = FakeGameSocketConnection()
        Self.installLivePrompt(
            model: model,
            gameID: gameID,
            ownerID: ownerID,
            projection: projection,
            connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let followsEnvelope = [
            Self.drawing(scenario: "theWitchingHour", arcana: "TemperanceXIV", facing: .reversed),
            Self.drawing(scenario: "theSecretName", arcana: "JusticeXI"),
        ]

        #expect(prompt.semanticPresentation?.presentation.drawings == mismatchedEnvelope)
        #expect(!prompt.isRenderableQuestion)
        #expect(!prompt.canSubmit)
        let result = await model.submitPickDestinyAnswer(
            prompt.identity,
            drawings: followsEnvelope
        )
        #expect(result == .readOnly)
        #expect(await connection.sentData.isEmpty)
    }

    private func localizedModuleString(
        _ key: String,
        fallback: String,
        locale: String
    ) throws -> String {
        let bundle = try moduleBundle(locale: locale)
        return NSLocalizedString(key, bundle: bundle, value: fallback, comment: "")
    }

    private func moduleBundle(locale: String) throws -> Bundle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/ArkhamHorrorShared/Localization")
            .appending(path: "\(locale).lproj")
        return try #require(Bundle(url: url))
    }

    private func localizableStrings(locale: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/ArkhamHorrorShared/Localization")
            .appending(path: "\(locale).lproj/Localizable.strings")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func appModelWithCatalog(
        entries: [String: String]
    ) async throws -> AppModel {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            pack: "pick-destiny",
            entryKeys: entries.keys.sorted(),
            chunkEntries: localeCatalogChunkEntries(entries)
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [documents.profile], selectedID: documents.profile.id
            ),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.compatible(
                capabilities: [LocaleCatalogLimits.capabilityIdentifier],
                localeCatalog: documents.advertisement
            ))),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            localeCatalogLoader: documents.loader(),
            preferredLanguagesProvider: PickDestinyPreferredLanguages(preferredLanguages: ["en"])
        )
        await model.flowTask?.value
        await model.localeCatalogTask?.value
        return model
    }

    private static func localeCatalogChunkEntries(
        _ entries: [String: String]
    ) throws -> String {
        let pairs = try entries.keys.sorted().map { key in
            try "\(jsonLiteral(key)):\(messageEntryJSON(text: entries[key] ?? ""))"
        }
        return "{\(pairs.joined(separator: ","))}"
    }

    private static func messageEntryJSON(text: String) throws -> String {
        try "{\"form\":\"message\",\"nodes\":[{\"type\":\"text\",\"value\":"
            + jsonLiteral(text) + "}],\"variables\":[]}"
    }

    private static func jsonLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return try #require(String(data: data, encoding: .utf8))
    }

    private static func promptPresentation(
        ownerID: PlayerID,
        drawings: [QuestionPresentation.DestinyDrawing],
        includeResolvedPrompt: Bool = false
    ) throws -> BasicChoicePromptPresentation {
        let payload = try Self.payload(drawings: drawings)
        let semanticPresentation = try #require(payload.presentation)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: ownerID,
                questionVersion: 0,
                rawQuestion: payload.rawValue,
                questionPresentation: semanticPresentation.presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            semanticPresentation: semanticPresentation,
            pickDestinyPrompt: includeResolvedPrompt
                ? .resolved(Self.resolvedPickDestinyPrompt(drawings: drawings))
                : nil,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private static func resolvedPickDestinyPrompt(
        drawings: [QuestionPresentation.DestinyDrawing]
    ) -> PickDestinyPromptPresentation {
        PickDestinyPromptPresentation(
            title: "Pick Destiny",
            instructions: "Reverse half the tarot cards.",
            doneLabel: "Done",
            drawings: drawings,
            rows: drawings.map {
                PickDestinyPromptPresentation.Row(
                    scenarioTitle: Self.scenarioTitle($0.scenario),
                    tarotTitle: $0.tarot.arcana
                )
            }
        )
    }

    private static func scenarioTitle(_ scenario: JSONValue) -> String {
        guard case let .string(value) = scenario else { return "Scenario" }
        return value
    }

    private static func projection(
        ownerID: PlayerID,
        prompt: BasicChoicePromptPresentation
    ) -> BoardProjection {
        let payload = BasicChoiceQuestionPayload(
            rawValue: prompt.identity.rawQuestion,
            state: prompt.question,
            presentation: prompt.semanticPresentation
        )
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            questions: [ownerID: payload]
        ))
    }

    private static func payload(
        drawings: [QuestionPresentation.DestinyDrawing]
    ) throws -> BasicChoiceQuestionPayload {
        try payload(rawDrawings: drawings, presentationDrawings: drawings)
    }

    private static func payload(
        rawDrawings: [QuestionPresentation.DestinyDrawing],
        presentationDrawings: [QuestionPresentation.DestinyDrawing]
    ) throws -> BasicChoiceQuestionPayload {
        let rawQuestion = rawQuestion(drawings: rawDrawings)
        let presentation = Self.questionPresentation(drawings: presentationDrawings)
        return try BasicChoiceQuestionPayload(
            rawValue: rawQuestion,
            state: .updateRequired(tag: "PickDestiny"),
            presentation: presentation.bind(to: rawQuestion, expectedQuestionVersion: 0)
        )
    }

    private static func questionPresentation(
        drawings: [QuestionPresentation.DestinyDrawing]
    ) -> QuestionPresentation {
        QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: 0,
            questionKind: .pickDestiny,
            choiceCount: 0,
            choices: [],
            answer: .pickDestiny,
            drawings: drawings
        )
    }

    private static func rawQuestion(
        drawings: [QuestionPresentation.DestinyDrawing]
    ) -> JSONValue {
        .object([
            "tag": .string("PickDestiny"),
            "drawings": .array(drawings.map(drawingJSON)),
        ])
    }

    private static func drawingJSON(
        _ drawing: QuestionPresentation.DestinyDrawing
    ) -> JSONValue {
        .object([
            "scenario": drawing.scenario,
            "tarot": .object([
                "facing": .string(drawing.tarot.facing.rawValue),
                "arcana": .string(drawing.tarot.arcana),
            ]),
        ])
    }

    private static func drawing(
        scenario: String,
        arcana: String,
        facing: QuestionPresentation.TarotCard.Facing = .upright
    ) -> QuestionPresentation.DestinyDrawing {
        QuestionPresentation.DestinyDrawing(
            scenario: .string(scenario),
            tarot: QuestionPresentation.TarotCard(facing: facing, arcana: arcana)
        )
    }

    private static func installLivePrompt(
        model: AppModel,
        gameID: GameID,
        ownerID: PlayerID,
        projection: BoardProjection,
        connection: FakeGameSocketConnection
    ) {
        let attemptID = UUID()
        model.liveGameParticipantIdentities[gameID] = .participant(ownerID)
        model.liveGameStates[gameID] = .live(projection)
        model.liveGameSessions[gameID] = LiveGameSessionHandle(attemptID: attemptID, task: Task {})
        model.liveGameConnections[gameID] = LiveGameConnectionHandle(
            attemptID: attemptID,
            connectionID: UUID(),
            connection: connection
        )
    }
}

// swiftlint:enable file_length
