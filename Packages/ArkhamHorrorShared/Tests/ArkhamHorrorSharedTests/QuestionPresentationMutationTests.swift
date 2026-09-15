@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Semantic question presentation governed mutations")
struct QuestionPresentationMutationTests {
    private enum RejectionStage {
        case decoding
        case binding
        case actionability
    }

    @Test("All seven backend-published Gathering mutations fail closed")
    func governedGatheringMutationsFailClosed() throws {
        let stages = try governedNegativeEntries().map {
            try rejectionStage(for: $0)
        }
        #expect(stages.count == 7)
        #expect(stages.count { $0 == .decoding } == 4)
        #expect(stages.count { $0 == .binding } == 1)
        #expect(stages.count { $0 == .actionability } == 2)
    }

    private func governedNegativeEntries() throws -> [[String: JSONValue]] {
        let manifest = try ContractJSON.decode(
            JSONValue.self,
            from: fixtureData(named: "manifest")
        )
        guard case let .object(root) = manifest,
              case let .array(negativeFixtures)? = root["negativeFixtures"]
        else { throw TestFailure() }
        return negativeFixtures.compactMap { value in
            guard case let .object(entry) = value,
                  case let .string(baseFixture)? = entry["basePositiveFixture"],
                  rawFixtureName(for: baseFixture) != nil
            else { return nil }
            return entry
        }
    }

    private func rejectionStage(
        for entry: [String: JSONValue]
    ) throws -> RejectionStage {
        guard case let .string(baseFixture)? = entry["basePositiveFixture"],
              let rawFixture = rawFixtureName(for: baseFixture),
              case let .string(basePointer)? = entry["basePointer"],
              case let .object(mutation)? = entry["mutation"],
              case let .string(operation)? = mutation["op"],
              case let .string(pointer)? = mutation["pointer"]
        else { throw TestFailure() }

        let presentationFixture = try fixtureValue(
            named: (baseFixture as NSString).lastPathComponent
                .replacingOccurrences(of: ".json", with: "")
        )
        let mutated = try EnemyAttackFixtures.applying(
            operation: operation,
            path: (basePointer + pointer).split(separator: "/"),
            replacement: mutation["value"],
            to: presentationFixture
        )
        let presentation: QuestionPresentation
        do {
            presentation = try ContractJSON.decode(
                QuestionPresentation.self,
                from: ContractJSON.encode(mutated)
            )
        } catch {
            return .decoding
        }

        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: fixtureData(named: rawFixture)
        )
        let bound: BoundQuestionPresentation
        do {
            bound = try presentation.bind(
                to: payload.rawValue,
                expectedQuestionVersion: presentation.questionVersion
            )
        } catch {
            return .binding
        }
        try expectActionabilityRejection(
            presentation: presentation,
            payload: payload,
            bound: bound
        )
        return .actionability
    }

    private func expectActionabilityRejection(
        presentation: QuestionPresentation,
        payload: BasicChoiceQuestionPayload,
        bound: BoundQuestionPresentation
    ) throws {
        let prompt = BasicChoicePromptPresentation(
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
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        let advanceChoice = try #require(
            prompt.choices.first {
                bound.descriptor(forSourceIndex: $0.index)?.kind == .advanceAct
            }
        )
        #expect(!prompt.isChoiceActionable(
            advanceChoice,
            in: gatheringProjection()
        ))
    }

    private func rawFixtureName(for path: String) -> String? {
        switch path {
        case "contracts/fixtures/question-presentation-gathering-act-objective.json":
            "question-gathering-act-objective"
        case "contracts/fixtures/question-presentation-gathering-act-advance.json":
            "question-gathering-act-advance"
        default:
            nil
        }
    }

    private func gatheringProjection() -> BoardProjection {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let actID = BoardTestFixtures.actID("c01108")
        return BoardProjectionBuilder.makeProjection(
            from: BoardTestFixtures.snapshot(
                investigators: [
                    investigatorID: BoardTestFixtures.investigator(id: investigatorID),
                ],
                acts: [
                    actID: BoardTestFixtures.act(id: actID),
                ],
                activeInvestigatorID: investigatorID,
                leadInvestigatorID: investigatorID
            )
        )
    }

    private func fixtureValue(named name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixtureData(named: name))
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }
}
