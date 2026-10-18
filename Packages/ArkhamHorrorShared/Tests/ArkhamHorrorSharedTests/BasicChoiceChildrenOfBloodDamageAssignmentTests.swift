@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Children of Blood enemy attack damage assignment")
struct CoBDamageAssignmentTests {
    @Test("Terminal live assignments parse as governed choices")
    func terminalLiveAssignmentsParse() throws {
        let cases = try ChildrenOfBloodDamageAssignmentFixtures.cases()

        for testCase in cases {
            let raw = try ChildrenOfBloodDamageAssignmentFixtures.value(testCase.fixture)
            let prompt = try DamageAssignmentFixtures.prompt(raw)
            let question = try #require(prompt.question.supportedQuestion)
            #expect(question.kind == .questionWithSource)
            #expect(!question.choices.contains { !$0.isSupported })
            #expect(question.choices.count == testCase.expectedTargets.count)
            let enemyID = try ChildrenOfBloodDamageAssignmentFixtures.enemyID(in: raw)
            let assetID = testCase.expectedTargets.compactMap { target in
                if case let .asset(assetID) = target {
                    assetID
                } else {
                    nil
                }
            }.first
            let projection = ChildrenOfBloodDamageAssignmentFixtures.projection(
                enemyID: enemyID,
                investigatorID: testCase.investigatorID,
                investigatorName: testCase.investigatorName,
                assetID: assetID
            )
            #expect(prompt.choices.map {
                BoardDisplayFormatting.choiceDisplayTitle(for: $0, in: projection)
            } == testCase.displayTitles)
            #expect(prompt.choices.allSatisfy { prompt.isChoiceActionable($0, in: projection) })

            let rawChoices = try ChildrenOfBloodDamageAssignmentFixtures.rawChoices(in: raw)
            for (choice, expectedTarget) in zip(question.choices, testCase.expectedTargets) {
                guard case let .assignEnemyAttackDamage(assignment) = choice.content else {
                    Issue.record("Expected enemy-attack damage assignment content")
                    continue
                }
                #expect(assignment.kind == .damage)
                #expect(assignment.enemyID == enemyID)
                #expect(assignment.investigatorID == testCase.investigatorID)
                #expect(assignment.target == expectedTarget)
                guard case let .object(rawChoice) = rawChoices[choice.index],
                      case let .array(rawMessages)? = rawChoice["messages"]
                else { throw TestFailure() }
                #expect(assignment.messages == rawMessages)
            }
        }
    }

    @Test("Malformed terminal assignment tails fail closed")
    func malformedOppositeTailFailsClosed() throws {
        var mutated = try ChildrenOfBloodDamageAssignmentFixtures.value(
            "question-live-cob-skids-q39-enemy-attack-damage-assignment"
        )
        mutated = try EnemyAttackFixtures.applying(
            operation: "replace",
            path: "/question/question/choices/0/messages/1/contents/contents/5"
                .split(separator: "/"),
            replacement: .number(.integer(1)),
            to: mutated
        )
        mutated = try EnemyAttackFixtures.applying(
            operation: "replace",
            path: "/question/question/choices/0/messages/1/contents/contents/7"
                .split(separator: "/"),
            replacement: .array([
                .object([
                    "tag": .string("InvestigatorTarget"),
                    "contents": .string("c01003"),
                ]),
            ]),
            to: mutated
        )

        try ChildrenOfBloodDamageAssignmentFixtures.expectFailClosed(mutated)
    }

    @Test("Asset soak choices without the deferred message fail closed")
    func assetSoakRequiresDeferredMessage() throws {
        let mutated = try EnemyAttackFixtures.applying(
            operation: "replace",
            path: "/question/question/choices/1/messages/0/tag".split(separator: "/"),
            replacement: .string("InvestigatorMessage"),
            to: ChildrenOfBloodDamageAssignmentFixtures.value(
                "question-live-cob-roland-q76-enemy-attack-damage-assignment"
            )
        )

        try ChildrenOfBloodDamageAssignmentFixtures.expectFailClosed(mutated)
    }
}

@MainActor
private enum ChildrenOfBloodDamageAssignmentFixtures {
    struct Case {
        let fixture: String
        let investigatorID: InvestigatorID
        let investigatorName: CardName
        let expectedTargets: [EnemyAttackDamageAssignmentTarget]
        let displayTitles: [String]
    }

    static func cases() throws -> [Case] {
        try [
            Case(
                fixture: "question-live-cob-skids-q39-enemy-attack-damage-assignment",
                investigatorID: BoardTestFixtures.investigatorID("c01003"),
                investigatorName: CardName(title: "\"Skids\" O'Toole", subtitle: nil),
                expectedTargets: [
                    .investigator(BoardTestFixtures.investigatorID("c01003")),
                ],
                displayTitles: ["Assign 1 damage to \"Skids\" O'Toole"]
            ),
            Case(
                fixture: "question-live-cob-roland-q76-enemy-attack-damage-assignment",
                investigatorID: BoardTestFixtures.investigatorID("c01001"),
                investigatorName: CardName(title: "Roland Banks", subtitle: "The Fed"),
                expectedTargets: [
                    .investigator(BoardTestFixtures.investigatorID("c01001")),
                    .asset(#require(AssetID(codingKey: AnyCodingKey(
                        stringValue: "77142f24-cb7e-41a4-b536-9580722ee63c"
                    )))),
                ],
                displayTitles: [
                    "Assign 1 damage to Roland Banks",
                    "Assign 1 damage to Guard Dog",
                ]
            ),
        ]
    }

    static func value(_ name: String) throws -> JSONValue {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/LiveChildrenOfBloodPlaythrough"
        ))
        return try ContractJSON.decode(JSONValue.self, from: Data(contentsOf: url))
    }

    static func enemyID(in raw: JSONValue) throws -> EnemyID {
        guard case let .object(root) = raw,
              case let .object(source)? = root["source"],
              case let .string(rawEnemyID)? = source["contents"],
              let enemyID = EnemyID(codingKey: AnyCodingKey(stringValue: rawEnemyID))
        else { throw TestFailure() }
        return enemyID
    }

    static func rawChoices(in raw: JSONValue) throws -> [JSONValue] {
        guard case let .object(root) = raw,
              case let .object(labelQuestion)? = root["question"],
              case let .object(chooseOne)? = labelQuestion["question"],
              case let .array(rawChoices)? = chooseOne["choices"]
        else { throw TestFailure() }
        return rawChoices
    }

    static func expectFailClosed(_ raw: JSONValue) throws {
        let prompt = try DamageAssignmentFixtures.prompt(raw)
        let projection = DamageAssignmentFixtures.projection()
        if case .updateRequired = prompt.question {} else {
            Issue.record("Expected the assignment root to require an update")
        }
        #expect(prompt.choices.isEmpty)
        let controller = BoardCommandController(projection: projection, prompt: prompt)
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(1)))
        #expect(!controller.activatePromptChoice(0))
        #expect(!controller.activatePromptChoice(1))
    }

    static func projection(
        enemyID: EnemyID,
        investigatorID: InvestigatorID,
        investigatorName: CardName,
        assetID: AssetID?
    ) -> BoardProjection {
        let investigators = [
            investigatorID: BoardTestFixtures.investigator(
                id: investigatorID,
                name: investigatorName,
                assets: assetID.map { [$0] } ?? []
            ),
        ]
        let assetValues = assetID.map {
            [
                $0: JSONValue.object([
                    "assetId": .string($0.codingKey.stringValue),
                    "cardCode": .string("c01021"),
                    "name": .string("Guard Dog"),
                ]),
            ]
        } ?? [:]
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: investigators,
            playerOrder: [investigatorID],
            enemyValues: [enemyID: .null],
            assetValues: assetValues
        ))
    }
}
