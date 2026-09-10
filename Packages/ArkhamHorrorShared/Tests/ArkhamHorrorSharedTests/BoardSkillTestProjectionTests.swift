@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Skill-test projection")
struct BoardSkillTestProjectionTests {
    @Test("Projects the backend's current values and authoritative result without recomputing it")
    func projectsAuthoritativeResult() throws {
        let skillTest = try value(
            """
            {
              "investigator": "c01001",
              "step": "ApplySkillTestResultsStep",
              "modifiedSkillValue": 8,
              "modifiedDifficulty": 2,
              "futureField": {"tag": "Additive"}
            }
            """
        )
        let results = try value(
            """
            {
              "skillTestResultsSkillValue": 8,
              "skillTestResultsIconValue": 3,
              "skillTestResultsChaosTokensValue": 2,
              "skillTestResultsDifficulty": 1,
              "skillTestResultsResultModifiers": -1,
              "skillTestResultsSuccess": false,
              "futureField": true
            }
            """
        )
        let projection = BoardSkillTestProjectionBuilder.makeProjection(
            skillTest: skillTest,
            results: results
        )

        guard case let .available(summary)? = projection else {
            Issue.record("Expected an available skill-test projection")
            return
        }
        #expect(summary.investigatorID.rawValue.rawValue == "c01001")
        #expect(summary.step == .applyResults)
        #expect(summary.modifiedSkillValue == 8)
        #expect(summary.modifiedDifficulty == 2)
        let result = try #require(summary.result)
        #expect(result.skillValue == 8)
        #expect(result.iconValue == 3)
        #expect(result.chaosTokensValue == 2)
        #expect(result.difficulty == 1)
        #expect(result.resultModifiers == -1)
        // Deliberately inconsistent numeric inputs prove the app preserves the
        // server-supplied verdict instead of implementing its own success rule.
        #expect(!result.succeeded)
    }

    @Test("Projects an in-progress test without inventing a result")
    func projectsInProgressTest() throws {
        let skillTest = try value(
            """
            {
              "investigator": "c01001",
              "step": "CommitCardsFromHandToSkillTestStep",
              "modifiedSkillValue": 4,
              "modifiedDifficulty": 3
            }
            """
        )
        let projection = BoardSkillTestProjectionBuilder.makeProjection(
            skillTest: skillTest,
            results: nil
        )

        guard case let .available(summary)? = projection else {
            Issue.record("Expected an available skill-test projection")
            return
        }
        #expect(summary.step == .commitCards)
        #expect(summary.modifiedSkillValue == 4)
        #expect(summary.modifiedDifficulty == 3)
        #expect(summary.result == nil)
    }

    @Test(
        "Unknown or malformed skill-test data fails closed",
        arguments: [
            #"""
            {
              "investigator":"C01001",
              "step":"CommitCardsFromHandToSkillTestStep",
              "modifiedSkillValue":4,
              "modifiedDifficulty":3
            }
            """#,
            #"""
            {
              "investigator":"c01001",
              "step":"FutureSkillTestStep",
              "modifiedSkillValue":4,
              "modifiedDifficulty":3
            }
            """#,
            #"""
            {
              "investigator":"c01001",
              "step":"CommitCardsFromHandToSkillTestStep",
              "modifiedSkillValue":4.0,
              "modifiedDifficulty":3
            }
            """#,
            #"""
            {
              "investigator":"c01001",
              "step":"CommitCardsFromHandToSkillTestStep",
              "modifiedSkillValue":4
            }
            """#,
        ]
    )
    func malformedTestFailsClosed(json: String) throws {
        let skillTest = try value(json)
        let projection = BoardSkillTestProjectionBuilder.makeProjection(
            skillTest: skillTest,
            results: nil
        )
        #expect(projection == .unavailable)
    }

    @Test("A malformed result fails closed rather than showing a success-shaped summary")
    func malformedResultFailsClosed() throws {
        let skillTest = try value(
            """
            {
              "investigator": "c01001",
              "step": "ApplySkillTestResultsStep",
              "modifiedSkillValue": 4,
              "modifiedDifficulty": 3
            }
            """
        )
        let results = try value(
            """
            {
              "skillTestResultsSkillValue": 4,
              "skillTestResultsIconValue": 0,
              "skillTestResultsChaosTokensValue": 0,
              "skillTestResultsDifficulty": 3,
              "skillTestResultsSuccess": true
            }
            """
        )
        let projection = BoardSkillTestProjectionBuilder.makeProjection(
            skillTest: skillTest,
            results: results
        )
        #expect(projection == .unavailable)
    }

    @Test("Result data without an active skill test is explicitly unavailable")
    func orphanedResultFailsClosed() throws {
        let results = try value(
            """
            {
              "skillTestResultsSkillValue": 4,
              "skillTestResultsIconValue": 0,
              "skillTestResultsChaosTokensValue": 0,
              "skillTestResultsDifficulty": 3,
              "skillTestResultsResultModifiers": null,
              "skillTestResultsSuccess": true
            }
            """
        )
        let projection = BoardSkillTestProjectionBuilder.makeProjection(
            skillTest: nil,
            results: results
        )
        #expect(projection == .unavailable)
    }

    private func value(_ json: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: Data(json.utf8))
    }
}
