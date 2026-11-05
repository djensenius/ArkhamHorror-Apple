@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Schema 0.1.57 question additions: the `chooseFromCollection` presentation kind renders
/// through the generic single-choice path, and the new `ResumeTurnPlayer` value of the
/// turn-player prompt degrades exactly like `SetTurnPlayer` already does.
@MainActor
@Suite("Schema 0.1.57 question kinds")
struct Schema157QuestionFallbackTests {
    /// Synthetic raw `ChooseFromCollection` (see "Schema 0.1.57 synthetic test shapes" in
    /// Fixtures/LegacyContract/PROVENANCE.md): the defaultOptions record encoding of
    /// Arkham/Question.hs:188 whose card codes match the captured `chooseFromCollection`
    /// representative.
    static func chooseFromCollection(
        cardCodes: JSONValue = .array([.string("c01001"), .string("c01002")])
    ) -> JSONValue {
        .object([
            "tag": .string("ChooseFromCollection"),
            "investigatorId": .string("c01001"),
            "source": .object(["tag": .string("GameSource")]),
            "cardCodes": cardCodes,
        ])
    }

    @Test("Captured chooseFromCollection representative decodes and binds by card index")
    func chooseFromCollectionBinds() throws {
        let presentation = try Self.collectionPresentation()
        #expect(presentation.questionKind == .chooseFromCollection)
        #expect(presentation.questionVersion == 337)
        #expect(presentation.choiceCount == 2)

        let raw = Self.chooseFromCollection()
        let binding = try presentation.bind(to: raw, expectedQuestionVersion: 337)
        #expect(binding.rawChoices == [.string("c01001"), .string("c01002")])
        #expect(binding.isRenderableInCurrentClient)

        let prompt = ContractFixtures.prompt(
            rawQuestion: raw, presentation: presentation, binding: binding
        )
        #expect(prompt.isRenderableQuestion)
        #expect(prompt.choices.map(\.index) == [0, 1])
        let projection = try BoardProjectionBuilder.makeProjection(
            from: Self.envelope(rawQuestion: raw, presentation: presentation).game
        )
        #expect(prompt.headerTitle(in: projection) == "Choose a card")
    }

    @Test("Malformed raw ChooseFromCollection questions fail the bind")
    func malformedChooseFromCollectionFailsClosed() throws {
        let presentation = try Self.collectionPresentation()
        guard case let .object(valid) = Self.chooseFromCollection() else {
            throw ContractFixtures.Failure.shape
        }
        var missingCodes = valid
        missingCodes["cardCodes"] = nil
        var missingSource = valid
        missingSource["source"] = nil
        var numericInvestigator = valid
        numericInvestigator["investigatorId"] = .number(.integer(1))
        let malformed: [JSONValue] = [
            .object(missingCodes),
            .object(missingSource),
            .object(numericInvestigator),
            Self.chooseFromCollection(cardCodes: .array([.string("c01001"), .null])),
            Self.chooseFromCollection(cardCodes: .array([.string("c01001")])),
            Self.chooseFromCollection(cardCodes: .string("c01001")),
        ]
        for raw in malformed {
            #expect(throws: QuestionPresentationBindingError.self, "\(raw)") {
                _ = try presentation.bind(to: raw, expectedQuestionVersion: 337)
            }
        }
    }

    @Test("A chooseFromCollection prompt sends the picked card's index")
    func chooseFromCollectionSendsBasicChoiceAnswer() async throws {
        let presentation = try Self.collectionPresentation()
        let envelope = try Self.envelope(
            rawQuestion: Self.chooseFromCollection(), presentation: presentation
        )
        let harness = AppModelLiveGameTests()
        let (model, fakes) = harness.makeSignedInModel()
        await model.flowTask?.value
        harness.makeModern(model)
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await harness.startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(prompt.isRenderableQuestion)
        let projection = try #require(model.liveGameState(for: gameID).lastKnownProjection)
        let choice = try #require(prompt.choices.first { $0.index == 1 })
        #expect(prompt.isChoiceActionable(choice, in: projection))
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: 1)
                == .sentAwaitingSnapshot
        )
        let expected = try ContractJSON.encode(BasicChoiceAnswer(
            choice: 1,
            playerID: #require(envelope.playerID),
            questionVersion: 337
        ))
        #expect(await connection.sentData == [expected])
    }

    @Test("ResumeTurnPlayer turn prompts fall back exactly like SetTurnPlayer ones")
    func resumeTurnPlayerFallsBack() throws {
        let presentation = try Self.turnPlayerPresentation()
        var bindings: [BoundQuestionPresentation] = []
        for value in ["SetTurnPlayer", "ResumeTurnPlayer"] {
            let raw = Self.turnPlayerQuestion(choice: value)
            #expect(BasicChoiceParser.parseQuestion(raw) == .updateRequired(tag: "QuestionLabel"))

            let envelope = try Self.envelope(rawQuestion: raw, presentation: presentation)
            let playerID = try #require(envelope.playerID)
            let payload = try #require(envelope.game.question[playerID], "\(value)")
            #expect(payload.rawValue == raw, "\(value)")
            #expect(payload.state == .updateRequired(tag: "QuestionLabel"), "\(value)")
            let binding = try #require(payload.presentation, "\(value)")
            #expect(binding.rawChoices.count == 2, "\(value)")
            bindings.append(binding)
        }
        #expect(bindings[0].presentation == bindings[1].presentation)
        #expect(
            bindings[0].isRenderableInCurrentClient == bindings[1].isRenderableInCurrentClient
        )
    }

    /// Synthetic turn-player prompt (see Fixtures/LegacyContract/PROVENANCE.md):
    /// Arkham/Game/Runner.hs
    /// `ChooseTurnPlayer` asks `questionLabel "$label.choosePlayerToTakeTurn"` over a
    /// `ChooseOne` of `PortraitLabel`s whose message is `ChoosePlayer iid <choice>`.
    static func turnPlayerQuestion(choice: String) -> JSONValue {
        let portraits: [JSONValue] = ["01001", "01002"].map { investigator in
            .object([
                "tag": .string("PortraitLabel"),
                "investigatorId": .string("c\(investigator)"),
                "messages": .array([.object([
                    "tag": .string("ChoosePlayer"),
                    "contents": .array([.string("c\(investigator)"), .string(choice)]),
                ])]),
            ])
        }
        return .object([
            "tag": .string("QuestionLabel"),
            "label": .string("$label.choosePlayerToTakeTurn"),
            "labelCards": .array([]),
            "question": .object(["tag": .string("ChooseOne"), "choices": .array(portraits)]),
        ])
    }

    /// Synthetic presentation of ``turnPlayerQuestion(choice:)``, following
    /// Arkham/Question/Presentation.hs: each `PortraitLabel` is a `chooseTarget` on its
    /// investigator, and the empty `labelCards` leave no `cardCode`.
    static func turnPlayerPresentation() throws -> QuestionPresentation {
        let choices: [JSONValue] = ["c01001", "c01002"].enumerated().map { index, id in
            .object([
                "kind": .string("chooseTarget"),
                "entity": .object(["kind": .string("investigator"), "id": .string(id)]),
                "selectable": .bool(true),
                "sourceIndex": .number(.integer(Int64(index))),
            ])
        }
        let presentation: JSONValue = .object([
            "answer": .object(["kind": .string("singleChoice"), "tag": .string("Answer")]),
            "choiceCount": .number(.integer(2)),
            "choices": .array(choices),
            "protocolVersion": .number(.integer(2)),
            "questionKind": .string("chooseOne"),
            "questionLabel": .object([
                "kind": .string("embeddedI18n"),
                "text": .string("$label.choosePlayerToTakeTurn"),
            ]),
            "questionVersion": .number(.integer(338)),
        ])
        return try ContractJSON.decode(
            QuestionPresentation.self, from: LosslessJSONSerializer.serialize(presentation)
        )
    }

    static func collectionPresentation() throws -> QuestionPresentation {
        try ContractJSON.decode(
            QuestionPresentation.self,
            from: LosslessJSONSerializer.serialize(
                ContractFixtures.representative(named: "chooseFromCollection")
            )
        )
    }

    /// The pinned Contract `get-game` envelope with its player's question replaced.
    static func envelope(
        rawQuestion: JSONValue,
        presentation: QuestionPresentation
    ) throws -> GetGameEnvelope {
        guard case var .object(root) = try LosslessJSONParser.parse(
            ContractFixtures.contractData("get-game")
        ),
            case var .object(game)? = root["game"],
            case let .string(playerID)? = root["playerId"]
        else { throw ContractFixtures.Failure.shape }
        game["question"] = .object([playerID: rawQuestion])
        game["questionPresentation"] = try .object([
            playerID: LosslessJSONParser.parse(ContractJSON.encode(presentation)),
        ])
        game["scenarioSteps"] = .number(.integer(Int64(presentation.questionVersion)))
        root["game"] = .object(game)
        return try ContractJSON.decode(
            GetGameEnvelope.self, from: LosslessJSONSerializer.serialize(.object(root))
        )
    }
}
