// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Standalone settings prompt")
// swiftlint:disable:next type_body_length
struct StandaloneSettingsPromptTests {
    @Test("Captured PickScenarioSettings prompt is renderable only for proven-empty 86001")
    func capturedPickScenarioSettingsPromptIsRenderable() throws {
        let prompt = try Self.prompt(
            named: "pick-scenario-settings",
            projection: Self.projection(scenarioID: "c86001")
        )

        #expect(prompt.isRenderableQuestion(in: Self.projection(scenarioID: "c86001")))
        #expect(prompt.isStandaloneSettingsPrompt(in: Self.projection(scenarioID: "c86001")))
        #expect(prompt.canSubmit)
        #expect(prompt.supportsStandaloneSettingsSubmission(
            [], in: Self.projection(scenarioID: "c86001")
        ))
        #expect(!prompt.supportsStandaloneSettingsSubmission(
            [.string("unexpected")], in: Self.projection(scenarioID: "c86001")
        ))
    }

    @Test("Midnight Masks standalone settings fail closed because the web has settings")
    func midnightMasksSettingsFailClosed() throws {
        let projection = Self.projection(scenarioID: "c01120")
        let prompt = try Self.prompt(named: "pick-scenario-settings", projection: projection)

        #expect(!prompt.isRenderableQuestion(in: projection))
        #expect(!prompt.isStandaloneSettingsPrompt(in: projection))
        #expect(!prompt.supportsStandaloneSettingsSubmission([], in: projection))
        #expect(!StandaloneScenarioSettingsCatalog.hasProvenEmptySettings(scenarioID: "01120"))
    }

    @Test("Empty-settings catalog documents web provenance and includes War of the Outer Gods")
    func emptySettingsCatalogProvenance() {
        #expect(
            StandaloneScenarioSettingsCatalog.sourceRepository
                == "https://github.com/djensenius/ArkhamHorror"
        )
        #expect(StandaloneScenarioSettingsCatalog.sourceCommit == ContractPin.current.backendCommit)
        #expect(StandaloneScenarioSettingsCatalog.hasProvenEmptySettings(scenarioID: "86001"))
        #expect(StandaloneScenarioSettingsCatalog.hasProvenEmptySettings(scenarioID: "c86001"))
        #expect(!StandaloneScenarioSettingsCatalog.hasProvenEmptySettings(scenarioID: nil))
    }

    @Test("Captured Laid to Rest prompt accepts player-selected cards in selected order")
    func laidToRestScenarioSpecificAnswerBytes() throws {
        let prompt = try Self.laidToRestPromptWithCatalog()
        let spiritDeck = try #require(prompt.laidToRestSpiritDeckPrompt)
        let selected = [
            "c01018", "c05151", "c12016", "c02106", "c09033", "c60107", "c01021",
            "c12018", "c60156",
        ]
        let answer = try #require(spiritDeck.answer(selectedCodes: selected))

        #expect(prompt.isRenderableQuestion)
        #expect(prompt.canSubmit)
        #expect(prompt.supportsScenarioSpecificSubmission(answer))
        let encoded = try ContractJSON.encode(ScenarioSpecificAnswer(contents: answer))
        let encodedString = try #require(String(data: encoded, encoding: .utf8))
        // swiftlint:disable:next line_length
        let expected = #"{"contents":["laidToRest.buildSpiritDeck",{"cardCodes":["c01018","c05151","c12016","c02106","c09033","c60107","c01021","c12018","c60156"]}],"tag":"ScenarioSpecificAnswer"}"#
        #expect(encodedString == expected)
    }

    @Test("Laid to Rest rejects non-subset, wrong count, duplicates, bad key and bad question kind")
    func laidToRestSubmissionNegatives() throws {
        let prompt = try Self.laidToRestPromptWithCatalog()
        let spiritDeck = try #require(prompt.laidToRestSpiritDeckPrompt)
        let valid = Array(spiritDeck.rawStringEntryCodes.prefix(9))
        let validAnswer: JSONValue = .array([
            .string(LaidToRestSpiritDeckPromptPresentation.key),
            .object(["cardCodes": .array(valid.map(JSONValue.string))]),
        ])
        #expect(prompt.supportsScenarioSpecificSubmission(validAnswer))

        let nonSubset = Array(valid.dropLast()) + ["c99999"]
        #expect(!prompt.supportsScenarioSpecificSubmission(Self.spiritDeckAnswer(nonSubset)))
        #expect(!prompt.supportsScenarioSpecificSubmission(
            Self.spiritDeckAnswer(Array(valid.dropLast()))
        ))
        #expect(!prompt.supportsScenarioSpecificSubmission(
            Self.spiritDeckAnswer(Array(valid.dropLast()) + [valid[0]])
        ))
        #expect(!prompt.supportsScenarioSpecificSubmission(.array([
            .string("wrong.key"), .object(["cardCodes": .array(valid.map(JSONValue.string))]),
        ])))

        let fixture = try Self.fixture(named: "pick-scenario-specific-laid-to-rest")
        let wrongPresentation = QuestionPresentation(
            protocolVersion: fixture.questionPresentation.protocolVersion,
            questionVersion: fixture.questionPresentation.questionVersion,
            questionKind: .pickCampaignSpecific,
            choiceCount: fixture.questionPresentation.choiceCount,
            choices: fixture.questionPresentation.choices,
            answer: fixture.questionPresentation.answer,
            key: fixture.questionPresentation.key,
            value: fixture.questionPresentation.value
        )
        let wrongKind = try BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(), ownerID: BoardTestFixtures.playerID(),
                questionVersion: fixture.questionVersion, rawQuestion: fixture.rawQuestion,
                questionPresentation: wrongPresentation, sessionAttemptID: nil, connectionID: nil
            ),
            question: .updateRequired(tag: "PickScenarioSpecific"),
            semanticPresentation: BoundQuestionPresentation(
                presentation: wrongPresentation,
                rawChoices: []
            ),
            cardCatalog: Self.cardCatalog(codes: Self.cardCodes(in: fixture.rawQuestion)),
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        #expect(wrongKind.laidToRestSpiritDeckPrompt == nil)
        #expect(!wrongKind.supportsScenarioSpecificSubmission(validAnswer))
    }

    @Test("Laid to Rest cards missing from the catalog stay selectable by code")
    func laidToRestMissingCatalogCardStaysSelectableByCode() throws {
        let fixture = try Self.fixture(named: "pick-scenario-specific-laid-to-rest")
        let allCodes = try Self.cardCodes(in: fixture.rawQuestion)
        let missingCode = try #require(allCodes.first)
        let prompt = try Self.laidToRestPromptWithCatalog(
            cardCatalog: Self.cardCatalog(codes: Array(allCodes.dropFirst()))
        )
        let spiritDeck = try #require(prompt.laidToRestSpiritDeckPrompt)
        let missingEntry = try #require(spiritDeck.entries.first)

        #expect(missingEntry.code == missingCode)
        #expect(missingEntry.displayName == nil)
        #expect(missingEntry.isSelectable)
        #expect(spiritDeck.toggledSelection([], entryAt: missingEntry.id) == [missingCode])
        let selected = [missingCode]
            + Array(spiritDeck.rawStringEntryCodes.dropFirst().prefix(spiritDeck.count - 1))
        #expect(spiritDeck.supportsSubmission(Self.spiritDeckAnswer(selected)))
    }

    @Test("Laid to Rest malformed prompt entries fail per entry and bad counts fail closed")
    func laidToRestMalformedPromptNegatives() throws {
        let nonStringPrompt = try Self.laidToRestPromptWithCatalog { raw, presentation in
            let changed = try Self.replacingLaidToRestPayload(raw) { payload in
                var changedPayload = payload
                guard case var .array(codes)? = changedPayload["cardCodes"] else {
                    return changedPayload
                }
                codes[0] = .number(.integer(7))
                changedPayload["cardCodes"] = .array(codes)
                return changedPayload
            }
            return (changed, presentation)
        }
        let nonStringDeck = try #require(nonStringPrompt.laidToRestSpiritDeckPrompt)
        #expect(nonStringDeck.entries[0].code == nil)
        #expect(!nonStringDeck.entries[0].isSelectable)
        #expect(nonStringDeck.entries[1].isSelectable)

        for badCount in [JSONValue.number(.integer(0)), .string("9"), .number(.integer(500))] {
            let badPrompt = try Self.laidToRestPromptWithCatalog { raw, presentation in
                let changed = try Self.replacingLaidToRestPayload(raw) { payload in
                    var changedPayload = payload
                    changedPayload["count"] = badCount
                    return changedPayload
                }
                return (changed, presentation)
            }
            #expect(badPrompt.laidToRestSpiritDeckPrompt == nil)
            #expect(!badPrompt.isRenderableQuestion)
        }
    }

    @Test("Laid to Rest controller toggles cards and focus graph exposes toggles plus confirm")
    @MainActor
    func laidToRestControllerAndFocusGraph() throws {
        let projection = Self.projection(scenarioID: "c90054")
        let prompt = try Self.laidToRestPromptWithCatalog()
        let spiritDeck = try #require(prompt.laidToRestSpiritDeckPrompt)
        var submitted: JSONValue?
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onScenarioSpecific: { submitted = $0 }
        )

        let focusIDs = controller.coordinator.graph.order
        #expect(focusIDs.contains(BoardFocusID.promptScenarioSpecificSubmit))
        #expect(focusIDs.contains(BoardFocusID.promptScenarioSpecificCard(0)))
        #expect(focusIDs.contains(
            BoardFocusID.promptScenarioSpecificCard(spiritDeck.count - 1)
        ))
        #expect(!controller.activateScenarioSpecificSubmit())

        let firstCode = try #require(spiritDeck.rawStringEntryCodes.first)
        controller.setSpiritDeckSearchText(firstCode)
        let filteredFocusIDs = controller.coordinator.graph.order
        #expect(controller.filteredSpiritDeckEntries(for: spiritDeck).map(\.id) == [0])
        #expect(filteredFocusIDs.contains(BoardFocusID.promptScenarioSpecificCard(0)))
        #expect(!filteredFocusIDs.contains(BoardFocusID.promptScenarioSpecificCard(1)))
        #expect(filteredFocusIDs.contains(BoardFocusID.promptScenarioSpecificSubmit))
        controller.setSpiritDeckSearchText("")

        for index in 0 ..< spiritDeck.count {
            #expect(controller.toggleSpiritDeckCard(at: index))
        }
        #expect(
            controller.spiritDeckSelection
                == Array(spiritDeck.rawStringEntryCodes.prefix(spiritDeck.count))
        )
        #expect(controller.activateScenarioSpecificSubmit())
        #expect(submitted == spiritDeck.answer(selectedCodes: controller.spiritDeckSelection))
    }

    @Test("Laid to Rest search survives snapshot and same-key prompt focus graph rebuilds")
    @MainActor
    func laidToRestSearchSurvivesControllerRebuilds() throws {
        let projection = Self.projection(scenarioID: "c90054")
        let prompt = try Self.laidToRestPromptWithCatalog()
        let spiritDeck = try #require(prompt.laidToRestSpiritDeckPrompt)
        let firstCode = try #require(spiritDeck.rawStringEntryCodes.first)
        let expectedVisibleIDs = spiritDeck.displayEntries(matching: firstCode).map(\.id)
        #expect(expectedVisibleIDs == [0])
        let controller = BoardCommandController(projection: projection, prompt: prompt)
        controller.setSpiritDeckSearchText(firstCode)

        func expectOnlyFilteredSpiritDeckFocus() {
            let focusedSpiritDeckIDs = spiritDeck.displayEntries.compactMap { entry in
                let focusID = BoardFocusID.promptScenarioSpecificCard(entry.id)
                return controller.coordinator.graph.contains(focusID) ? entry.id : nil
            }
            #expect(focusedSpiritDeckIDs == expectedVisibleIDs)
            #expect(controller.coordinator.graph.contains(
                BoardFocusID.promptScenarioSpecificSubmit
            ))
        }

        expectOnlyFilteredSpiritDeckFocus()
        controller.applySnapshot(projection, prompt: prompt)
        #expect(controller.spiritDeckSearchText == firstCode)
        expectOnlyFilteredSpiritDeckFocus()

        let sameKeyPrompt = Self.promptWithServerFeedback(
            "Transport refreshed while filtering.",
            prompt: prompt
        )
        #expect(sameKeyPrompt.identity.promptKey == prompt.identity.promptKey)
        #expect(sameKeyPrompt != prompt)
        controller.applyPrompt(sameKeyPrompt)
        #expect(controller.spiritDeckSearchText == firstCode)
        expectOnlyFilteredSpiritDeckFocus()
    }

    @Test("Standalone and spirit deck localization keys resolve in English and German")
    // swiftlint:disable:next function_body_length
    func localizedKeysResolve() {
        let keys: [StaticString] = [
            "standaloneSettings.message",
            "standaloneSettings.submit",
            "standaloneSettings.submit.hint",
            "scenarioSpecific.spiritDeck.message",
            "scenarioSpecific.spiritDeck.counter",
            "scenarioSpecific.spiritDeck.counter.format",
            "scenarioSpecific.spiritDeck.search",
            "scenarioSpecific.spiritDeck.submit",
            "scenarioSpecific.spiritDeck.submit.hint",
            "scenarioSpecific.spiritDeck.unresolvedCard",
            "scenarioSpecific.spiritDeck.malformedCard",
            "scenarioSpecific.spiritDeck.fixed.hint",
            "scenarioSpecific.spiritDeck.unselectable.hint",
            "scenarioSpecific.spiritDeck.selected.hint",
            "scenarioSpecific.spiritDeck.unselected.hint",
            "scenarioSpecific.spiritDeck.accessibility.fixed",
            "scenarioSpecific.spiritDeck.accessibility.selected",
            "scenarioSpecific.spiritDeck.accessibility.notSelected",
            "scenarioSpecific.spiritDeck.accessibility.toggle",
        ]
        for locale in ["en", "de"] {
            for key in keys {
                let value = Self.localizedModuleString(
                    key,
                    fallback: "__missing__",
                    locale: locale
                )
                #expect(value != "__missing__")
                #expect(!value.isEmpty)
            }
        }
        #expect(Self.localizedModuleString(
            "scenarioSpecific.spiritDeck.counter.format",
            fallback: "__missing__",
            locale: "en",
            arguments: [2, 9]
        ) == "Selected cards: 2 of 9")
        #expect(Self.localizedModuleString(
            "scenarioSpecific.spiritDeck.counter.format",
            fallback: "__missing__",
            locale: "de",
            arguments: [2, 9]
        ) == "Ausgewählte Karten: 2 von 9")
        #expect(Self.localizedModuleString(
            "scenarioSpecific.spiritDeck.accessibility.fixed",
            fallback: "__missing__",
            locale: "de",
            arguments: ["Card c01001", "c01001"]
        ) == "Card c01001, c01001, fest vorgegeben")
        #expect(Self.localizedModuleString(
            "scenarioSpecific.spiritDeck.accessibility.notSelected",
            fallback: "__missing__",
            locale: "de"
        ) == "nicht ausgewählt")
    }

    @Test("StandaloneSettingsAnswer empty settings encode exact server bytes")
    func emptyStandaloneSettingsAnswerBytes() throws {
        let encoded = try ContractJSON.encode(StandaloneSettingsAnswer(contents: []))
        let encodedString = try #require(String(data: encoded, encoding: .utf8))
        let expected = #"{"contents":[],"tag":"StandaloneSettingsAnswer"}"#
        #expect(encodedString == expected)
        let decoded = try ContractJSON.decode(StandaloneSettingsAnswer.self, from: encoded)
        #expect(decoded == StandaloneSettingsAnswer(contents: []))
    }

    private static func spiritDeckAnswer(_ codes: [String]) -> JSONValue {
        .array([
            .string(LaidToRestSpiritDeckPromptPresentation.key),
            .object(["cardCodes": .array(codes.map(JSONValue.string))]),
        ])
    }

    private static func laidToRestPromptWithCatalog(
        transform: (JSONValue, QuestionPresentation) throws -> (JSONValue, QuestionPresentation) = {
            ($0, $1)
        },
        cardCatalog: CardCatalogSnapshot? = nil
    ) throws -> BasicChoicePromptPresentation {
        let fixture = try Self.fixture(named: "pick-scenario-specific-laid-to-rest")
        let (rawQuestion, questionPresentation) = try transform(
            fixture.rawQuestion,
            fixture.questionPresentation
        )
        let binding = try questionPresentation.bind(
            to: rawQuestion,
            expectedQuestionVersion: fixture.questionVersion
        )
        let cardCodes = try Self.cardCodes(in: rawQuestion)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: fixture.questionVersion,
                rawQuestion: rawQuestion,
                questionPresentation: binding.presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: .updateRequired(tag: "PickScenarioSpecific"),
            semanticPresentation: binding,
            cardCatalog: cardCatalog ?? Self.cardCatalog(codes: cardCodes),
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private static func promptWithServerFeedback(
        _ serverFeedback: String,
        prompt: BasicChoicePromptPresentation
    ) -> BasicChoicePromptPresentation {
        BasicChoicePromptPresentation(
            identity: prompt.identity,
            question: prompt.question,
            semanticPresentation: prompt.semanticPresentation,
            semanticLocaleIdentifier: prompt.semanticLocaleIdentifier,
            cardCatalog: prompt.cardCatalog,
            storyResolution: prompt.storyResolution,
            choiceLabelResolutions: prompt.choiceLabelResolutions,
            choiceFlavorResolutions: prompt.choiceFlavorResolutions,
            promptLabelResolutions: prompt.promptLabelResolutions,
            pickDestinyPrompt: prompt.pickDestinyPrompt,
            readOnlyReason: prompt.readOnlyReason,
            actionPhase: prompt.actionPhase,
            actionChoiceIndex: prompt.actionChoiceIndex,
            serverFeedback: serverFeedback,
            catalogRetry: prompt.catalogRetry
        )
    }

    private static func prompt(
        named name: String,
        projection _: BoardProjection
    ) throws -> BasicChoicePromptPresentation {
        let fixture = try Self.fixture(named: name)
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(fixture.rawQuestion)
        )
        let binding = try fixture.questionPresentation.bind(
            to: fixture.rawQuestion,
            expectedQuestionVersion: fixture.questionVersion
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: fixture.questionVersion,
                rawQuestion: fixture.rawQuestion,
                questionPresentation: binding.presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            semanticPresentation: binding,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private static func projection(scenarioID: String) -> BoardProjection {
        BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            mode: .scenarioOnly(BoardTestFixtures.scenario(
                id: BoardTestFixtures.cardCode(scenarioID)
            ))
        ))
    }

    private static func replacingLaidToRestPayload(
        _ raw: JSONValue,
        transform: ([String: JSONValue]) throws -> [String: JSONValue]
    ) throws -> JSONValue {
        guard case var .object(object) = raw,
              case var .array(contents)? = object["contents"],
              contents.count == 2,
              case let .object(payload) = contents[1]
        else { return raw }
        contents[1] = try .object(transform(payload))
        object["contents"] = .array(contents)
        return .object(object)
    }

    private static func cardCodes(in raw: JSONValue) throws -> [String] {
        guard case let .object(object) = raw,
              case let .array(contents)? = object["contents"],
              contents.count == 2,
              case let .object(payload) = contents[1]
        else { return [] }
        var codes: [String] = []
        if case let .array(cardCodeValues)? = payload["cardCodes"] {
            codes += cardCodeValues.compactMap { value in
                guard case let .string(code) = value else { return nil }
                return code
            }
        }
        if case let .array(fixedValues)? = payload["fixed"] {
            codes += fixedValues.compactMap { value in
                guard case let .string(code) = value else { return nil }
                return code
            }
        }
        return codes
    }

    private static func cardCatalog(codes: [String]) -> CardCatalogSnapshot {
        var names: [CardCode: CardName] = [:]
        for code in codes {
            guard let cardCode = try? CardCode(code) else { continue }
            names[cardCode] = CardName(title: "Card \(code)", subtitle: nil)
        }
        return CardCatalogSnapshot(namesByCode: names)
    }

    private static func fixture(named name: String) throws -> CapturedPromptFixture {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/LiveStandaloneSettingsPrompt"
        ))
        return try ContractJSON.decode(CapturedPromptFixture.self, from: Data(contentsOf: url))
    }

    private static func localizedModuleString(
        _ key: StaticString,
        fallback: String,
        locale: String,
        arguments: [CVarArg] = []
    ) -> String {
        BasicChoicePromptPresentation.semanticLocalized(
            key,
            value: String.LocalizationValue(fallback),
            localeIdentifier: locale,
            arguments: arguments
        )
    }
}

private struct CapturedPromptFixture: Decodable {
    let questionVersion: Int
    let rawQuestion: JSONValue
    let questionPresentation: QuestionPresentation
}
