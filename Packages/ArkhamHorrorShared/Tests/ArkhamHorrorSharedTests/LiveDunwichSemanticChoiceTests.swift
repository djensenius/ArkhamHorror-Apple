@testable import ArkhamHorrorShared
import Foundation
import Testing

private enum BeginnersLuckFixtures {
    static let questionVersion = 11

    static func rawQuestionData() throws -> Data {
        try fixture("c02062-beginners-luck-q11-raw-question")
    }

    static func presentationData() throws -> Data {
        try fixture("c02062-beginners-luck-q11-question-presentation")
    }

    static func rawQuestionValue() throws -> JSONValue {
        try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: rawQuestionData()).rawValue
    }

    static func presentationValue() throws -> QuestionPresentation {
        try ContractJSON.decode(QuestionPresentation.self, from: presentationData())
    }

    static func chaosTokens() throws -> [ChaosToken] {
        guard case let .object(root) = try LosslessJSONParser.parse(rawQuestionData()),
              case let .array(choices)? = root["choices"]
        else { throw TestFailure() }
        return try choices.map { choice in
            guard case let .object(choiceObject) = choice,
                  case let .object(target)? = choiceObject["target"],
                  case let .object(contents)? = target["contents"]
            else { throw TestFailure() }
            return try ContractJSON.decode(
                ChaosToken.self,
                from: LosslessJSONSerializer.serialize(.object(contents))
            )
        }
    }

    static func prompt(
        choiceLabelResolutions: [Int: BasicChoiceLabelResolution]
    ) throws -> BasicChoicePromptPresentation {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: rawQuestionData()
        )
        let presentation = try presentationValue()
        let bound = try presentation.bind(
            to: payload.rawValue,
            expectedQuestionVersion: presentation.questionVersion
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: presentation.questionVersion,
                rawQuestion: payload.rawValue,
                questionPresentation: presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            semanticPresentation: bound,
            semanticLocaleIdentifier: "en",
            cardCatalog: nil,
            choiceLabelResolutions: choiceLabelResolutions,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    static func projection(focusesChaosTokens: Bool = true) throws -> BoardProjection {
        let tokens = try chaosTokens()
        let focusedTokens = focusesChaosTokens ? try chaosTokenValues(tokens) : []
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            mode: .scenarioOnly(BoardTestFixtures.scenario(
                chaosBag: BoardTestFixtures.chaosBag(chaosTokens: tokens)
            )),
            focusedChaosTokens: focusedTokens
        ))
    }

    static func chaosTokenValues(_ tokens: [ChaosToken]) throws -> [JSONValue] {
        try tokens.map { token in
            try ContractJSON.decode(JSONValue.self, from: ContractJSON.encode(token))
        }
    }

    static func catalogDocumentsWithOpaqueChoice() throws -> SyntheticLocaleCatalogDocuments {
        let chunkEntries = "{\"choice.opaque\":{\"form\":\"message\",\"nodes\":["
            + "{\"type\":\"text\",\"value\":\"Continue\"}],\"variables\":[]}}"
        return try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["choice.opaque"],
            chunkEntries: chunkEntries
        )
    }

    private static func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/LiveDunwich"
            )
        )
        return try Data(contentsOf: url)
    }
}

@Suite("Live Dunwich semantic choice regressions")
struct LiveDunwichSemanticChoiceTests {
    @Test("Captured Beginner's Luck target labels link to chaos tokens")
    @MainActor
    func capturedBeginnersLuckTargetLabelsLinkToChaosTokens() throws {
        let prompt = try BeginnersLuckFixtures.prompt(
            choiceLabelResolutions: Dictionary(uniqueKeysWithValues: (0 ..< 16).map {
                ($0, BasicChoiceLabelResolution.resolved("Continue"))
            })
        )
        let projection = try BeginnersLuckFixtures.projection()
        let tokens = projection.targetableChaosTokens
        let firstToken = try #require(tokens.first)
        let firstElement = BoardPromptElementID.chaosToken(firstToken.id)

        #expect(prompt.choices.map(\.index) == Array(0 ..< 16))
        #expect(prompt.displayOrderedChoices(in: projection).isEmpty)

        let links = BoardPromptChoiceLinker.links(prompt: prompt, projection: projection)
        #expect(links[firstElement] == [
            BoardLinkedChoice(
                choiceIndex: 0,
                title: "Continue",
                isActionable: true
            ),
        ])

        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onChoice: { submitted.append($0) }
        )
        let focusID = BoardFocusID.promptElement(firstElement)
        #expect(controller.coordinator.graph.contains(focusID))
        controller.coordinator.syncExternalFocus(focusID)
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0])
    }

    @Test("Captured Beginner's Luck tokens only in the bag keep their list buttons")
    @MainActor
    func capturedBeginnersLuckBagOnlyTokensStayInPromptList() throws {
        let prompt = try BeginnersLuckFixtures.prompt(
            choiceLabelResolutions: Dictionary(uniqueKeysWithValues: (0 ..< 16).map {
                ($0, BasicChoiceLabelResolution.resolved("Continue"))
            })
        )
        let projection = try BeginnersLuckFixtures.projection(focusesChaosTokens: false)

        #expect(projection.targetableChaosTokens.isEmpty)
        #expect(prompt.displayOrderedChoices(in: projection).map(\.index) == Array(0 ..< 16))
        #expect(BoardPromptChoiceLinker.links(prompt: prompt, projection: projection).isEmpty)
    }

    @Test("Captured Beginner's Luck unresolved opaque labels remain unpressable on tokens")
    @MainActor
    func capturedBeginnersLuckUnresolvedOpaqueLabelsFailClosedOnTargets() throws {
        let prompt = try BeginnersLuckFixtures.prompt(choiceLabelResolutions: [:])
        let projection = try BeginnersLuckFixtures.projection()
        let firstToken = try #require(projection.targetableChaosTokens.first)
        let firstElement = BoardPromptElementID.chaosToken(firstToken.id)

        #expect(prompt.displayOrderedChoices(in: projection).isEmpty)
        let links = BoardPromptChoiceLinker.links(prompt: prompt, projection: projection)
        let link = try #require(links[firstElement]?.first)
        #expect(link.choiceIndex == 0)
        #expect(link.title == prompt.displayTitle(for: prompt.choices[0], in: projection))
        #expect(!link.isActionable)

        let controller = BoardCommandController(projection: projection, prompt: prompt)
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptElement(firstElement)))
        #expect(!controller.activatePromptChoice(0))
    }

    @Test("Apple-only chaos-token target strings exist in English and German bundles")
    func appleOnlyChaosTokenTargetStringsResolveFromModuleBundle() {
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("en") {
            #expect(
                BoardLocalization.format(
                    "board.chaosToken.accessibility",
                    "__missing %@",
                    "Plus One"
                ) == "Chaos token Plus One"
            )
        }
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("de") {
            #expect(
                BoardLocalization.format(
                    "board.chaosToken.accessibility",
                    "__missing %@",
                    "Plus Eins"
                ) == "Chaosmarker Plus Eins"
            )
        }
    }
}

extension AppModelLiveGameTests {
    @Test("Captured Beginner's Luck submits the clicked chaos-token choice index through AppModel")
    func capturedBeginnersLuckAppModelTargetChoiceWithOpaqueCatalog() async throws {
        let documents = try BeginnersLuckFixtures.catalogDocumentsWithOpaqueChoice()
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        model.localeCatalog = try await documents.loadSnapshot()
        model.localeCatalogRequest = LocaleCatalogRequest(
            profileID: model.selectedProfile.id,
            advertisement: documents.advertisement
        )
        let envelope = try beginnersLuckEnvelope()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameState(for: gameID).lastKnownProjection)
        let firstToken = try #require(projection.targetableChaosTokens.first)
        let links = BoardPromptChoiceLinker.links(prompt: prompt, projection: projection)

        #expect(prompt.questionVersion == BeginnersLuckFixtures.questionVersion)
        #expect(prompt.choiceLabelResolutions[0] == .resolved("Continue"))
        #expect(prompt.displayOrderedChoices(in: projection).isEmpty)
        #expect(links[.chaosToken(firstToken.id)]?.first == BoardLinkedChoice(
            choiceIndex: 0,
            title: "Continue",
            isActionable: true
        ))
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: 0)
                == .sentAwaitingSnapshot
        )
        let expected = try ContractJSON.encode(BasicChoiceAnswer(
            choice: 0,
            playerID: prompt.ownerID,
            questionVersion: BeginnersLuckFixtures.questionVersion
        ))
        #expect(await connection.sentData == [expected])
    }

    @Test("Captured Beginner's Luck AppModel path fails closed without choice.opaque catalog text")
    func capturedBeginnersLuckAppModelTargetChoiceWithoutOpaqueCatalog() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try beginnersLuckEnvelope()
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let projection = try #require(model.liveGameState(for: gameID).lastKnownProjection)
        let firstToken = try #require(projection.targetableChaosTokens.first)
        let links = BoardPromptChoiceLinker.links(prompt: prompt, projection: projection)

        #expect(prompt.choiceLabelResolutions[0] == .unavailable(.catalog(.notAdvertised)))
        #expect(prompt.displayOrderedChoices(in: projection).isEmpty)
        #expect(links[.chaosToken(firstToken.id)]?.first == BoardLinkedChoice(
            choiceIndex: 0,
            title: prompt.displayTitle(for: prompt.choices[0], in: projection),
            isActionable: false
        ))
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: 0)
                == .unsupportedChoice
        )
        #expect(await connection.sentData.isEmpty)
    }

    private func beginnersLuckEnvelope() throws -> GetGameEnvelope {
        var root = try jsonObject(from: fixtureData(named: "get-game"))
        let rawQuestion = try jsonObject(from: BeginnersLuckFixtures.rawQuestionData())
        let presentation = try jsonObject(from: BeginnersLuckFixtures.presentationData())
        let tokens = try beginnersLuckTokenObjects(from: rawQuestion)
        guard let playerID = root["playerId"] as? String,
              var game = root["game"] as? [String: Any],
              var questions = game["question"] as? [String: Any],
              var presentations = game["questionPresentation"] as? [String: Any],
              var mode = game["mode"] as? [String: Any],
              var scenario = mode["That"] as? [String: Any],
              var chaosBag = scenario["chaosBag"] as? [String: Any]
        else { throw TestFailure() }

        questions[playerID] = rawQuestion
        presentations[playerID] = presentation
        chaosBag["chaosTokens"] = tokens
        scenario["chaosBag"] = chaosBag
        mode["That"] = scenario
        game["question"] = questions
        game["questionPresentation"] = presentations
        game["focusedChaosTokens"] = tokens
        game["scenarioSteps"] = BeginnersLuckFixtures.questionVersion
        game["mode"] = mode
        root["game"] = game

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return try ContractJSON.decode(GetGameEnvelope.self, from: data)
    }

    private func beginnersLuckTokenObjects(
        from rawQuestion: [String: Any]
    ) throws -> [[String: Any]] {
        guard let choices = rawQuestion["choices"] as? [[String: Any]] else { throw TestFailure() }
        return try choices.map { choice in
            guard let target = choice["target"] as? [String: Any],
                  let contents = target["contents"] as? [String: Any]
            else { throw TestFailure() }
            return contents
        }
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure()
        }
        return object
    }
}
