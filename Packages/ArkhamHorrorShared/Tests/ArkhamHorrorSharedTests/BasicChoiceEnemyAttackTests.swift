@testable import ArkhamHorrorShared
import Foundation
import Testing

enum EnemyAttackFixtures {
    static let enemyID = BoardTestFixtures.enemyID("000000000386")
    static let investigatorID = BoardTestFixtures.investigatorID("c01001")

    static func data(_ name: String = "question-enemy-attack") throws -> Data {
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

    static func prompt(
        _ value: JSONValue, phase: BasicChoiceActionPhase? = nil
    ) throws -> BasicChoicePromptPresentation {
        let payload = try payload(value)
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID("000000000001"),
                questionVersion: 5,
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

    static func projection(
        includeEnemy: Bool = true, includeInvestigator: Bool = true
    ) -> BoardProjection {
        let investigators: [InvestigatorID: Investigator] = includeInvestigator
            ? [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    name: CardName(title: "Roland Banks", subtitle: "The Fed")
                ),
            ]
            : [:]
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: investigators,
            playerOrder: includeInvestigator ? [investigatorID] : [],
            enemyValues: includeEnemy ? [enemyID: .null] : [:]
        ))
    }

    /// Applies one backend manifest mutation in memory; governed fixture bytes stay untouched.
    static func applying(
        operation: String, path: [Substring], replacement: JSONValue?, to value: JSONValue
    ) throws -> JSONValue {
        guard let component = path.first else {
            guard operation == "replace" || operation == "add" else { throw TestFailure() }
            return try #require(replacement)
        }
        let tail = Array(path.dropFirst())
        switch value {
        case let .object(object):
            return try applyingToObject(
                object, operation: operation, component: component, tail: tail,
                replacement: replacement
            )
        case let .array(array):
            return try applyingToArray(
                array, operation: operation, component: component, tail: tail,
                replacement: replacement
            )
        default:
            throw TestFailure()
        }
    }

    private static func applyingToObject(
        _ input: [String: JSONValue],
        operation: String,
        component: Substring,
        tail: [Substring],
        replacement: JSONValue?
    ) throws -> JSONValue {
        var object = input
        let key = String(component)
        if tail.isEmpty, operation == "remove" {
            let removed = object.removeValue(forKey: key)
            _ = try #require(removed)
        } else if tail.isEmpty {
            guard let replacement else { throw TestFailure() }
            object[key] = replacement
        } else {
            object[key] = try applying(
                operation: operation,
                path: tail,
                replacement: replacement,
                to: #require(object[key])
            )
        }
        return .object(object)
    }

    private static func applyingToArray(
        _ input: [JSONValue],
        operation: String,
        component: Substring,
        tail: [Substring],
        replacement: JSONValue?
    ) throws -> JSONValue {
        var array = input
        if tail.isEmpty, component == "-", operation == "add" {
            try array.append(#require(replacement))
            return .array(array)
        }
        let index = try #require(Int(component))
        try #require(array.indices.contains(index))
        if tail.isEmpty, operation == "remove" {
            array.remove(at: index)
        } else if tail.isEmpty {
            array[index] = try #require(replacement)
        } else {
            array[index] = try applying(
                operation: operation,
                path: tail,
                replacement: replacement,
                to: array[index]
            )
        }
        return .array(array)
    }
}

@MainActor
@Suite("Enemy attack choice")
struct BasicChoiceEnemyAttackTests {
    @Test("The governed attack parses exact identities, opaque message, title, and answer bytes")
    func fixturePresentationAndEncoding() throws {
        let raw = try EnemyAttackFixtures.value()
        let prompt = try EnemyAttackFixtures.prompt(raw)
        let question = try #require(prompt.question.supportedQuestion)
        #expect(question.kind == .chooseOneAtATime)
        #expect(question.choices.map(\.index) == [0])
        let choice = try #require(question.choices.first)
        guard case let .resolveEnemyAttack(
            enemyID, investigatorID, messages
        ) = choice.content else {
            Issue.record("Expected the governed enemy attack")
            return
        }
        #expect(enemyID == EnemyAttackFixtures.enemyID)
        #expect(investigatorID == EnemyAttackFixtures.investigatorID)
        guard case let .object(root) = raw,
              case let .array(rawChoices)? = root["choices"],
              case let .object(rawChoice) = rawChoices.first,
              case let .array(rawMessages)? = rawChoice["messages"]
        else { throw TestFailure() }
        #expect(messages == rawMessages)
        #expect(choice.title == "Resolve enemy attack")
        #expect(choice.systemImage == "shield.fill")
        try expectPublishedTitle(choice)

        let projection = EnemyAttackFixtures.projection()
        #expect(prompt.isChoiceActionable(choice, in: projection))
        #expect(BoardDisplayFormatting.choiceDisplayTitle(
            for: choice, in: projection
        ) == "Resolve enemy attack against Roland Banks")
        #expect(BoardDisplayFormatting.choiceAccessibilityHint(
            for: choice, in: projection, canSubmit: true, statusMessage: nil
        ) == "Activates choice 1.")
        #expect(try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(EnemyAttackFixtures.payload(raw))
        ) == raw)

        try expectPublishedAnswer(choice: choice, prompt: prompt)
    }

    @Test("All 86 backend-published enemy attack mutations fail closed")
    func governedMutationsFailClosed() throws {
        let manifest = try ContractJSON.decode(
            JSONValue.self, from: EnemyAttackFixtures.data("manifest")
        )
        guard case let .object(root) = manifest,
              case let .array(negatives)? = root["negativeFixtures"]
        else { throw TestFailure() }
        let fixturePath = JSONValue.string("contracts/fixtures/question-enemy-attack.json")
        var checked = 0
        for case let .object(entry) in negatives where entry["basePositiveFixture"] == fixturePath {
            guard case let .string(base)? = entry["basePointer"],
                  case let .object(mutation)? = entry["mutation"],
                  case let .string(pointer)? = mutation["pointer"],
                  case let .string(operation)? = mutation["op"]
            else { throw TestFailure() }
            let mutated = try EnemyAttackFixtures.applying(
                operation: operation,
                path: (base + pointer).split(separator: "/"),
                replacement: mutation["value"],
                to: EnemyAttackFixtures.value()
            )
            try expectFailClosed(mutated)
            checked += 1
        }
        #expect(checked == 86)
    }

    @Test("Repeated enemy and investigator identities must match dynamically")
    func repeatedIdentitiesMustMatch() throws {
        let alternateEnemy = JSONValue.string("00000000-0000-0000-0000-000000000387")
        for path in [
            "/choices/0/target/contents",
            "/choices/0/messages/0/contents/contents/attackEnemy",
            "/choices/0/messages/0/contents/contents/attackSource/contents",
        ] {
            let mutated = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: alternateEnemy,
                to: EnemyAttackFixtures.value()
            )
            try expectFailClosed(mutated)
        }
        for path in [
            "/choices/0/messages/0/contents/contents/attackTarget/contents/contents",
            "/choices/0/messages/0/contents/contents/attackOriginalTarget/contents/contents",
        ] {
            let mutated = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: .string("c01002"),
                to: EnemyAttackFixtures.value()
            )
            try expectFailClosed(mutated)
        }
    }

    @Test("Only the exact one-choice wrapper gains authority")
    func wrapperAndCardinalityFailClosed() throws {
        let genericChoice = JSONValue.object([
            "tag": .string("EndTurnButton"),
            "investigatorId": .string("c01001"),
            "messages": .array([]),
        ])
        for choices in [[], [genericChoice], [genericChoice, genericChoice]] {
            let raw = JSONValue.object([
                "tag": .string("ChooseOneAtATime"),
                "choices": .array(choices),
            ])
            try expectFailClosed(raw)
        }

        let canonical = try EnemyAttackFixtures.value()
        guard case let .object(root) = canonical,
              case let .array(choices)? = root["choices"],
              let attackChoice = choices.first
        else { throw TestFailure() }
        let genericRoot = JSONValue.object([
            "tag": .string("ChooseOne"),
            "choices": .array([attackChoice]),
        ])
        let genericPayload = try EnemyAttackFixtures.payload(genericRoot)
        let genericParsedChoice = try #require(genericPayload.supportedQuestion?.choices.first)
        #expect(genericParsedChoice.content == .unsupported(tag: "TargetLabel"))
    }

    @Test("Actionability tracks both projection identities and enemy IDs sort deterministically")
    func projectionIdentityActionability() throws {
        let prompt = try EnemyAttackFixtures.prompt(EnemyAttackFixtures.value())
        let choice = try #require(prompt.choices.first)
        let present = EnemyAttackFixtures.projection()
        #expect(present.isChoiceActionable(choice))
        #expect(!EnemyAttackFixtures.projection(includeEnemy: false).isChoiceActionable(choice))
        #expect(
            !EnemyAttackFixtures.projection(includeInvestigator: false).isChoiceActionable(choice)
        )
        #expect(BoardDisplayFormatting.choiceAccessibilityHint(
            for: choice,
            in: EnemyAttackFixtures.projection(includeEnemy: false),
            canSubmit: true,
            statusMessage: nil
        ) == "The enemy or investigator for this attack isn't currently available.")

        let low = BoardTestFixtures.enemyID("000000000001")
        let high = BoardTestFixtures.enemyID("000000000999")
        let sorted = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            enemyValues: [high: .bool(true), EnemyAttackFixtures.enemyID: .null, low: .string("x")]
        ))
        #expect(sorted.enemyIDs == [low, EnemyAttackFixtures.enemyID, high])
    }

    @Test("Controller activation and pending/retry focus preserve source index zero")
    func controllerAndPendingFocus() throws {
        let raw = try EnemyAttackFixtures.value()
        let projection = EnemyAttackFixtures.projection()
        var submitted: [Int] = []
        var retries = 0
        let controller = try BoardCommandController(
            projection: projection,
            prompt: EnemyAttackFixtures.prompt(raw),
            onChoice: { submitted.append($0) },
            onRetry: { retries += 1 }
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0])

        for phase in [BasicChoiceActionPhase.sending, .awaitingSnapshot, .uncertain] {
            try controller.applyPrompt(EnemyAttackFixtures.prompt(raw, phase: phase))
            #expect(!controller.activatePromptChoice(0))
            #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
        }
        try controller.applyPrompt(EnemyAttackFixtures.prompt(
            raw, phase: .retryable(.transportFailure)
        ))
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptRetry)
        #expect(controller.handle(.command(.primaryAction)))
        #expect(retries == 1)
    }

    private func expectFailClosed(_ raw: JSONValue) throws {
        let prompt = try EnemyAttackFixtures.prompt(raw)
        let projection = EnemyAttackFixtures.projection()
        if let question = prompt.question.supportedQuestion {
            #expect(question.choices.allSatisfy { !$0.isSupported })
            #expect(question.choices.allSatisfy { !prompt.isChoiceActionable($0, in: projection) })
        } else {
            if case .updateRequired = prompt.question {} else {
                Issue.record("Expected the specialized root to require an update")
            }
            #expect(prompt.choices.isEmpty)
        }
        let controller = BoardCommandController(projection: projection, prompt: prompt)
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
        #expect(!controller.activatePromptChoice(0))
    }

    private func expectPublishedTitle(_ choice: BasicChoice) throws {
        let schema = try JSONSerialization.jsonObject(
            with: EnemyAttackFixtures.data("basic-choice-question.schema")
        ) as? [String: Any]
        let definitions = try #require(schema?["$defs"] as? [String: Any])
        let branch = try #require(
            definitions["chooseOneAtATimeEnemyAttackQuestion"] as? [String: Any]
        )
        #expect(choice.title == branch["title"] as? String)
    }

    private func expectPublishedAnswer(
        choice: BasicChoice, prompt: BasicChoicePromptPresentation
    ) throws {
        let answer = BasicChoiceAnswer(
            choice: choice.index, playerID: prompt.ownerID, questionVersion: 5
        )
        let published = try ContractJSON.decode(
            BasicChoiceAnswer.self,
            from: EnemyAttackFixtures.data("answer-enemy-attack")
        )
        #expect(answer == published)
        #expect(try ContractJSON.encode(answer) == ContractJSON.encode(published))
    }
}
