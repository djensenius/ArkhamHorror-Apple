@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Enemy attack assignment continuation mutations")
struct AssignmentContinuationMutationTests {
    private let amountPaths = [
        "/question/question/choices/0/messages/0/contents/contents/2",
        "/question/question/choices/0/messages/0/contents/contents/3",
        "/question/question/choices/0/messages/1/contents/contents/4",
        "/question/question/choices/0/messages/1/contents/contents/5",
    ]

    @Test(
        "All 16 backend-published mutations for each continuation fail closed",
        arguments: AssignmentContinuationFixture.allCases
    )
    func governedMutationsFailClosed(
        _ fixture: AssignmentContinuationFixture
    ) throws {
        let manifest = try ContractJSON.decode(
            JSONValue.self,
            from: DamageAssignmentFixtures.contractData("manifest")
        )
        guard case let .object(root) = manifest,
              case let .array(negatives)? = root["negativeFixtures"]
        else { throw TestFailure() }
        let fixturePath = JSONValue.string(
            "contracts/fixtures/\(fixture.questionFixture).json"
        )
        var checked = 0
        var rejectedAssetWithTitleMatcher = false
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
                to: DamageAssignmentFixtures.continuationValue(fixture)
            )
            try DamageAssignmentFixtures.expectContinuationFailClosed(mutated)
            if mutation["value"] == .string("AssetWithTitle") {
                #expect(operation == "replace")
                #expect(base + pointer
                    == "/question/question/choices/0/messages/1/contents/contents/3/tag")
                rejectedAssetWithTitleMatcher = true
            }
            checked += 1
        }
        #expect(checked == 16)
        #expect(rejectedAssetWithTitleMatcher)
    }

    @Test(
        "Every repeated identity and amount remains coherent and canonical",
        arguments: AssignmentContinuationFixture.allCases
    )
    func repeatedIdentityAndAmountCoherence(
        _ fixture: AssignmentContinuationFixture
    ) throws {
        let raw = try DamageAssignmentFixtures.continuationValue(fixture)
        try expectIdentityMismatchesFailClosed(raw)
        try expectAmountMismatchesFailClosed(raw, fixture: fixture)
    }

    @Test(
        "Consistent valid identity rebinding remains semantic",
        arguments: AssignmentContinuationFixture.allCases
    )
    func consistentlyReboundIdentitiesParse(
        _ fixture: AssignmentContinuationFixture
    ) throws {
        let alternateEnemy = BoardTestFixtures.enemyID("000000000389")
        let alternateInvestigator = BoardTestFixtures.investigatorID("c01002")
        var rebound = try DamageAssignmentFixtures.continuationValue(fixture)
        for path in DamageAssignmentFixtures.continuationEnemyIdentityPaths {
            rebound = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: .string(alternateEnemy.codingKey.stringValue),
                to: rebound
            )
        }
        for path in DamageAssignmentFixtures.continuationInvestigatorIdentityPaths {
            rebound = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: .string(alternateInvestigator.codingKey.stringValue),
                to: rebound
            )
        }

        let prompt = try DamageAssignmentFixtures.continuationPrompt(
            fixture,
            value: rebound
        )
        let choice = try #require(prompt.choices.first)
        guard case let .assignEnemyAttackDamage(assignment) = choice.content else {
            Issue.record("Expected a rebound \(fixture.rawValue) assignment")
            return
        }
        #expect(assignment.kind == fixture.assignmentKind)
        #expect(assignment.enemyID == alternateEnemy)
        #expect(assignment.investigatorID == alternateInvestigator)
        let projection = DamageAssignmentFixtures.projection(
            enemyID: alternateEnemy,
            investigatorID: alternateInvestigator
        )
        #expect(prompt.isChoiceActionable(choice, in: projection))
    }

    private func expectIdentityMismatchesFailClosed(_ raw: JSONValue) throws {
        let alternateEnemy = BoardTestFixtures.enemyID("000000000389")
        for path in DamageAssignmentFixtures.continuationEnemyIdentityPaths {
            let mutated = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: .string(alternateEnemy.codingKey.stringValue),
                to: raw
            )
            try DamageAssignmentFixtures.expectContinuationFailClosed(mutated)
        }
        for path in DamageAssignmentFixtures.continuationInvestigatorIdentityPaths {
            let mutated = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: .string("c01002"),
                to: raw
            )
            try DamageAssignmentFixtures.expectContinuationFailClosed(mutated)
        }
    }

    private func expectAmountMismatchesFailClosed(
        _ raw: JSONValue,
        fixture: AssignmentContinuationFixture
    ) throws {
        let amounts = [
            fixture.directAmounts.damage,
            fixture.directAmounts.horror,
            Int64(0),
            Int64(0),
        ]
        for (path, expected) in zip(amountPaths, amounts) {
            let mutated = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: .number(.integer(expected == 0 ? 1 : 0)),
                to: raw
            )
            try DamageAssignmentFixtures.expectContinuationFailClosed(mutated)

            let token = expected == 0 ? "-0" : "1e0"
            let noncanonical = try ContractJSON.decode(
                JSONValue.self,
                from: Data(token.utf8)
            )
            let noncanonicalMutation = try EnemyAttackFixtures.applying(
                operation: "replace",
                path: path.split(separator: "/"),
                replacement: noncanonical,
                to: raw
            )
            try DamageAssignmentFixtures.expectContinuationFailClosed(
                noncanonicalMutation
            )
        }
    }
}
