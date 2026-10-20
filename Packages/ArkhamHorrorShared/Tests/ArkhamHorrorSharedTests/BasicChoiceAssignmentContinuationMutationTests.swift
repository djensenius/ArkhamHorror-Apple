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
        """
        Backend-published continuation mutations fail closed except the live terminal \
        empty-opposite shape
        """,
        arguments: AssignmentContinuationFixture.allCases
    )
    func governedMutationsFailClosed(
        _ fixture: AssignmentContinuationFixture
    ) throws {
        let negatives = try negativeFixtures(for: fixture)
        var checked = 0
        var rejected = 0
        var acceptedTerminalEmptyOppositeList = false
        var rejectedAssetWithTitleMatcher = false
        for case let .object(entry) in negatives {
            guard case let .string(base)? = entry["basePointer"],
                  case let .object(mutation)? = entry["mutation"],
                  case let .string(pointer)? = mutation["pointer"],
                  case let .string(operation)? = mutation["op"]
            else { throw TestFailure() }
            let mutationPath = base + pointer
            let mutated = try EnemyAttackFixtures.applying(
                operation: operation,
                path: mutationPath.split(separator: "/"),
                replacement: mutation["value"],
                to: DamageAssignmentFixtures.continuationValue(fixture)
            )
            if isTerminalEmptyOppositeListMutation(
                operation: operation,
                path: mutationPath,
                value: mutation["value"],
                fixture: fixture
            ) {
                try expectAcceptedTerminalEmptyOppositeList(mutated, fixture: fixture)
                acceptedTerminalEmptyOppositeList = true
            } else {
                try DamageAssignmentFixtures.expectContinuationFailClosed(mutated)
                rejected += 1
            }
            if mutation["value"] == .string("AssetWithTitle") {
                #expect(operation == "replace")
                #expect(mutationPath
                    == "/question/question/choices/0/messages/1/contents/contents/3/tag")
                rejectedAssetWithTitleMatcher = true
            }
            checked += 1
        }
        #expect(checked == 16)
        #expect(rejected == 15)
        #expect(acceptedTerminalEmptyOppositeList)
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

    private func negativeFixtures(
        for fixture: AssignmentContinuationFixture
    ) throws -> [JSONValue] {
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
        return negatives.filter { entry in
            guard case let .object(object) = entry else { return false }
            return object["basePositiveFixture"] == fixturePath
        }
    }

    private func isTerminalEmptyOppositeListMutation(
        operation: String,
        path: String,
        value: JSONValue?,
        fixture: AssignmentContinuationFixture
    ) -> Bool {
        // The backend manifest still marks both terminal candidate-list removals as
        // negative examples from the governed 0.1.53 fixtures. The Children of Blood
        // live proof showed the opposite candidate list can lawfully be empty once the
        // opposite remaining amount is exactly zero, so only that one historical
        // mutation is now a positive compatibility shape. The same-side target list
        // and all other manifest mutations still fail closed below.
        operation == "replace"
            && path == fixture.emptyOppositeListPath
            && value == .array([])
    }

    private func expectAcceptedTerminalEmptyOppositeList(
        _ raw: JSONValue,
        fixture: AssignmentContinuationFixture
    ) throws {
        let prompt = try DamageAssignmentFixtures.continuationPrompt(
            fixture,
            value: raw
        )
        let choice = try #require(prompt.choices.first)
        #expect(prompt.choices.count == 1)
        #expect(choice.isSupported)
        guard case let .assignEnemyAttackDamage(assignment) = choice.content else {
            Issue.record(
                "Expected accepted terminal empty-opposite mutation to remain an assignment"
            )
            return
        }
        #expect(assignment.kind == fixture.assignmentKind)
        #expect(assignment.enemyID == DamageAssignmentFixtures.enemyID)
        #expect(assignment.investigatorID == DamageAssignmentFixtures.investigatorID)
        #expect(assignment.target == .investigator(DamageAssignmentFixtures.investigatorID))
        #expect(prompt.isChoiceActionable(choice, in: DamageAssignmentFixtures.projection()))
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
