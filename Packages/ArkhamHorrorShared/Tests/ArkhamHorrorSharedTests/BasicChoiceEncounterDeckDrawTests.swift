@testable import ArkhamHorrorShared
import Foundation
import Testing

enum EncounterDeckDrawFixtures {
    static func data(_ name: String = "question-encounter-deck-draw") throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/Contract"
        ))
        return try Data(contentsOf: url)
    }

    static func value() throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: data())
    }

    static func payload(_ value: JSONValue) throws -> BasicChoiceQuestionPayload {
        try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: ContractJSON.encode(value))
    }

    /// Applies fixture mutations in memory; never edits the governed golden bytes.
    static func replacing(
        _ value: JSONValue, at path: [Substring], with replacement: JSONValue?
    ) throws -> JSONValue {
        guard let key = path.first else { return try #require(replacement) }
        let tail = Array(path.dropFirst())
        switch value {
        case var .object(object):
            if tail.isEmpty {
                object[String(key)] = replacement
            } else {
                object[String(key)] = try replacing(
                    #require(object[String(key)]), at: tail, with: replacement
                )
            }
            return .object(object)
        case var .array(array):
            let index = try #require(Int(key))
            try #require(array.indices.contains(index))
            if tail.isEmpty, replacement == nil {
                array.remove(at: index)
            } else {
                array[index] = try replacing(array[index], at: tail, with: replacement)
            }
            return .array(array)
        default:
            throw TestFailure()
        }
    }

    static func prompt(
        _ value: JSONValue, phase: BasicChoiceActionPhase? = nil
    ) throws -> BasicChoicePromptPresentation {
        let payload = try payload(value)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: 3,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            readOnlyReason: nil,
            actionPhase: phase,
            actionChoiceIndex: phase == nil ? nil : 0,
            serverFeedback: nil
        )
    }
}

@MainActor
@Suite("Encounter deck draw")
struct BasicChoiceEncounterDeckDrawTests {
    @Test("The production fixture uses the backend's semantic title and exact source index zero")
    func fixturePresentationAndEncoding() throws {
        let raw = try EncounterDeckDrawFixtures.value()
        let prompt = try EncounterDeckDrawFixtures.prompt(raw)
        let question = try #require(prompt.question.supportedQuestion)
        #expect(question.kind == .chooseOne)
        #expect(question.choices.map(\.index) == [0])
        let choice = try #require(question.choices.first)
        guard case let .drawEncounterCard(investigatorID, messages) = choice.content else {
            Issue.record("Expected the governed encounter draw")
            return
        }
        #expect(investigatorID.rawValue.rawValue == "c01001")
        #expect(messages.count == 1)
        #expect(choice.localizationKey == nil)
        let schema = try JSONSerialization.jsonObject(
            with: EncounterDeckDrawFixtures.data("basic-choice-question.schema")
        ) as? [String: Any]
        let definitions = try #require(schema?["$defs"] as? [String: Any])
        let branch = try #require(definitions["encounterDeckDrawLabel"] as? [String: Any])
        #expect(choice.title == branch["title"] as? String)
        #expect(choice.title == "Draw encounter card")
        let board = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        #expect(prompt.isChoiceActionable(choice, in: board))
        #expect(BoardDisplayFormatting.choiceDisplayTitle(
            for: choice, in: board
        ) == "Draw encounter card")
        #expect(BoardDisplayFormatting.choiceAccessibilityHint(
            for: choice, in: board, canSubmit: true, statusMessage: nil
        ) == "Activates choice 1.")
        #expect(try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(EncounterDeckDrawFixtures.payload(raw))
        ) == raw)
        let answer = BasicChoiceAnswer(
            choice: choice.index, playerID: prompt.ownerID, questionVersion: 3
        )
        let expected = Data(
            """
            {"contents":{"choice":0,"playerId":"00000000-0000-0000-0000-000000000001",\
            "questionVersion":3},"tag":"Answer"}
            """.utf8
        )
        #expect(try ContractJSON.encode(answer) == expected)
        #expect(try ContractJSON.decode(BasicChoiceAnswer.self, from: expected) == answer)
    }

    @Test("Every backend-published encounter mutation stays explicit unsupported")
    func governedMutationsFailClosed() throws {
        let manifest = try ContractJSON.decode(
            JSONValue.self, from: EncounterDeckDrawFixtures.data("manifest")
        )
        guard case let .object(root) = manifest,
              case let .array(negatives)? = root["negativeFixtures"]
        else { throw TestFailure() }
        var checked = 0
        let fixturePath = JSONValue.string("contracts/fixtures/question-encounter-deck-draw.json")
        for case let .object(entry) in negatives where entry["basePositiveFixture"] == fixturePath {
            guard case let .string(base)? = entry["basePointer"],
                  case let .object(mutation)? = entry["mutation"],
                  case let .string(pointer)? = mutation["pointer"],
                  case let .string(operation)? = mutation["op"]
            else { throw TestFailure() }
            #expect(["add", "remove", "replace"].contains(operation))
            let mutated = try EncounterDeckDrawFixtures.replacing(
                EncounterDeckDrawFixtures.value(),
                at: (base + pointer).split(separator: "/"),
                with: operation == "remove" ? nil : mutation["value"]
            )
            try expectUnsupported(mutated)
            checked += 1
        }
        #expect(checked == 47)
    }

    @Test("All twelve closed draw fields are required even when their values are nullable")
    func missingFieldsFailClosed() throws {
        let raw = try EncounterDeckDrawFixtures.value()
        let fields = [
            "cardDrawAction", "cardDrawAlreadyDrawn", "cardDrawAmount", "cardDrawAndThen",
            "cardDrawDeck", "cardDrawDiscard", "cardDrawKind", "cardDrawPosition",
            "cardDrawRules", "cardDrawSource", "cardDrawState", "cardDrawTarget",
        ]
        for field in fields {
            try expectUnsupported(EncounterDeckDrawFixtures.replacing(
                raw,
                at: "/choices/0/messages/0/contents/1/\(field)".split(separator: "/"),
                with: nil
            ))
        }
    }

    @Test(
        "Draw amount never normalizes decimal, exponent, negative-zero or large numeric tokens",
        arguments: ["1.0", "1e0", "1.00000000000000000001", "-0", "1e999", "9223372036854775808"]
    )
    func numericBoundaries(token: String) throws {
        let fixture = try #require(String(data: EncounterDeckDrawFixtures.data(), encoding: .utf8))
        let bytes = Data(fixture.replacingOccurrences(
            of: #""cardDrawAmount": 1"#, with: #""cardDrawAmount": \#(token)"#
        ).utf8)
        try expectUnsupported(ContractJSON.decode(JSONValue.self, from: bytes))
    }

    @Test("Other question contexts and shifted source indices never acquire draw authority")
    func contextBoundaries() throws {
        let raw = try EncounterDeckDrawFixtures.value()
        for tag in ["WindowChooseOne", "PlayerWindowChooseOne"] {
            try expectUnsupported(EncounterDeckDrawFixtures.replacing(
                raw, at: ["tag"], with: .string(tag)
            ))
        }
        let question = try #require(EncounterDeckDrawFixtures.payload(raw).supportedQuestion)
        let draw = try #require(question.choices.first?.rawValue)
        try expectUnsupported(EncounterDeckDrawFixtures.replacing(
            raw, at: ["choices"], with: .array([.object(["tag": .string("FutureChoice")]), draw])
        ), index: 1)
        let duplicate = try EncounterDeckDrawFixtures.payload(EncounterDeckDrawFixtures.replacing(
            raw, at: ["choices"], with: .array([draw, draw])
        ))
        #expect(duplicate.supportedQuestion?.choices.map(\.index) == [0, 1])
        #expect(duplicate.supportedQuestion?.choices.map(\.isSupported) == [true, false])
    }

    @Test("Additional messages and contents cannot be mistaken for the closed one-card draw")
    func arrayBoundaries() throws {
        let raw = try EncounterDeckDrawFixtures.value()
        let question = try #require(EncounterDeckDrawFixtures.payload(raw).supportedQuestion)
        guard case let .drawEncounterCard(_, messages) = question.choices[0].content,
              case let .object(message) = messages[0],
              case let .array(contents)? = message["contents"]
        else { throw TestFailure() }
        try expectUnsupported(EncounterDeckDrawFixtures.replacing(
            raw, at: "/choices/0/messages".split(separator: "/"), with: .array(messages + messages)
        ))
        for invalid in [[], Array(contents.prefix(1)), contents + [.null]] {
            try expectUnsupported(EncounterDeckDrawFixtures.replacing(
                raw,
                at: "/choices/0/messages/0/contents".split(separator: "/"),
                with: .array(invalid)
            ))
        }
    }

    private func expectUnsupported(_ raw: JSONValue, index: Int = 0) throws {
        let prompt = try EncounterDeckDrawFixtures.prompt(raw)
        let choice = try #require(prompt.choices.first { $0.index == index })
        #expect(choice.content == .unsupported(tag: "TargetLabel"))
        #expect(choice.title == "Update required")
        let board = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        #expect(!prompt.isChoiceActionable(choice, in: board))
        #expect(BoardDisplayFormatting.choiceAccessibilityHint(
            for: choice, in: board, canSubmit: true, statusMessage: nil
        ) == "This choice requires a newer app version.")
        let controller = BoardCommandController(projection: board, prompt: prompt)
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(index)))
        #expect(!controller.activatePromptChoice(index))
    }
}

@MainActor
extension BasicChoiceEncounterDeckDrawTests {
    @Test("Native, keyboard, gamepad and Siri Remote activation share source index zero")
    func nativeFocusAndInputActivation() throws {
        let prompt = try EncounterDeckDrawFixtures.prompt(EncounterDeckDrawFixtures.value())
        let board = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: board, prompt: prompt, onChoice: { submitted.append($0) }
        )
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.handle(focusID: BoardFocusID.promptChoice(0), .command(.primaryAction)))
        let commands = [
            InputMappingTable.defaultKeyboard.command(for: .keyboard(.enter)),
            InputMappingTable.defaultGamepad.command(for: .controller(.buttonA)),
            InputMappingTable.defaultSiriRemote.command(for: .siriRemote(.select)),
        ]
        for command in commands {
            #expect(try controller.handle(.command(#require(command))))
        }
        #expect(submitted == [0, 0, 0, 0])
        controller.applyPrompt(nil)
        #expect(controller.coordinator.currentFocus == BoardFocusID.scenarioHeader)
    }

    @Test("Pending draw disables stale native controls and retry receives semantic focus")
    func pendingAndRetryFocus() throws {
        let raw = try EncounterDeckDrawFixtures.value()
        let board = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        var choices: [Int] = []
        var retries = 0
        let controller = try BoardCommandController(
            projection: board, prompt: EncounterDeckDrawFixtures.prompt(raw),
            onChoice: { choices.append($0) }, onRetry: { retries += 1 }
        )
        for phase in [BasicChoiceActionPhase.sending, .awaitingSnapshot, .uncertain] {
            let pending = try EncounterDeckDrawFixtures.prompt(raw, phase: phase)
            controller.applyPrompt(pending)
            #expect(!pending.canSubmit)
            #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
            #expect(!controller.activatePromptChoice(0))
            #expect(!controller.handle(
                focusID: BoardFocusID.promptChoice(0), .command(.primaryAction)
            ))
        }
        try controller.applyPrompt(EncounterDeckDrawFixtures.prompt(
            raw, phase: .retryable(.transportFailure)
        ))
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptRetry))
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptRetry)
        #expect(controller.handle(.command(.primaryAction)))
        #expect(retries == 1)
        #expect(choices.isEmpty)
    }
}
