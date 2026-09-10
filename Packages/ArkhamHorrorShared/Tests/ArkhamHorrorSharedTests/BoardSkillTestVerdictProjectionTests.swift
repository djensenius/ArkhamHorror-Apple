@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Live skill-test verdict projection")
struct BoardSkillTestVerdictProjectionTests {
    @Test("Projects the production apply prompt's embedded verdict without a breakdown")
    func projectsEmbeddedVerdict() throws {
        let skillTest = try value(
            """
            {
              "investigator": "c01001",
              "step": "DetermineSuccessOrFailureOfSkillTestStep",
              "modifiedSkillValue": 3,
              "modifiedDifficulty": 2,
              "result": {
                "tag": "SucceededBy",
                "contents": ["NonAutomatic", 0]
              }
            }
            """
        )
        let projection = BoardSkillTestProjectionBuilder.makeProjection(
            skillTest: skillTest,
            results: nil
        )

        guard case let .available(summary)? = projection else {
            Issue.record("Expected the production verdict to be available")
            return
        }
        #expect(summary.step == .determineResult)
        #expect(summary.result == nil)
        #expect(summary.verdict == .init(succeeded: true, amount: 0, automatic: false))
        #expect(summary.verdict?.displayLabel == "Succeeded by 0")
    }

    @Test("Preserves the backend's automatic failure verdict")
    func projectsAutomaticFailure() throws {
        let skillTest = try value(
            """
            {
              "investigator": "c01001",
              "step": "DetermineSuccessOrFailureOfSkillTestStep",
              "modifiedSkillValue": 3,
              "modifiedDifficulty": 2,
              "result": {
                "tag": "FailedBy",
                "contents": ["Automatic", 2]
              }
            }
            """
        )
        let projection = BoardSkillTestProjectionBuilder.makeProjection(
            skillTest: skillTest,
            results: nil
        )

        guard case let .available(summary)? = projection else {
            Issue.record("Expected the automatic verdict to be available")
            return
        }
        #expect(summary.verdict == .init(succeeded: false, amount: 2, automatic: true))
        #expect(summary.verdict?.displayLabel == "Automatically failed by 2")
    }

    @Test("A malformed embedded verdict fails closed")
    func malformedVerdictFailsClosed() throws {
        let skillTest = try value(
            """
            {
              "investigator": "c01001",
              "step": "DetermineSuccessOrFailureOfSkillTestStep",
              "modifiedSkillValue": 3,
              "modifiedDifficulty": 2,
              "result": {
                "tag": "SucceededBy",
                "contents": ["FutureAutomaticity", 0]
              }
            }
            """
        )
        let projection = BoardSkillTestProjectionBuilder.makeProjection(
            skillTest: skillTest,
            results: nil
        )
        #expect(projection == .unavailable)
    }

    @Test("Conflicting backend verdict surfaces fail closed")
    func conflictingVerdictsFailClosed() throws {
        let skillTest = try value(
            """
            {
              "investigator": "c01001",
              "step": "DetermineSuccessOrFailureOfSkillTestStep",
              "modifiedSkillValue": 3,
              "modifiedDifficulty": 2,
              "result": {
                "tag": "SucceededBy",
                "contents": ["NonAutomatic", 0]
              }
            }
            """
        )
        let results = try value(
            """
            {
              "skillTestResultsSkillValue": 3,
              "skillTestResultsIconValue": 0,
              "skillTestResultsChaosTokensValue": -1,
              "skillTestResultsDifficulty": 2,
              "skillTestResultsResultModifiers": null,
              "skillTestResultsSuccess": false
            }
            """
        )
        let projection = BoardSkillTestProjectionBuilder.makeProjection(
            skillTest: skillTest,
            results: results
        )
        #expect(projection == .unavailable)
    }

    private func value(_ json: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: Data(json.utf8))
    }
}
