@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    func snapshotUpdate(
        from envelope: GetGameEnvelope,
        scenarioSteps: Int,
        mutateRawQuestion: Bool = false,
        questionTag: String? = nil
    ) throws -> BoardSnapshotUpdate {
        let data = try ContractJSON.encode(envelope.game)
        var value = try ContractJSON.decode(JSONValue.self, from: data)
        guard case var .object(object) = value else { throw TestFailure() }
        object["scenarioSteps"] = .number(.integer(Int64(scenarioSteps)))
        if questionTag == nil {
            try updateQuestionPresentationVersion(
                in: &object,
                scenarioSteps: scenarioSteps
            )
        }
        if mutateRawQuestion {
            try appendFutureNestedMessage(in: &object)
        }
        if let questionTag {
            try replaceQuestionTag(in: &object, with: questionTag)
        }
        value = .object(object)
        let snapshot = try ContractJSON.decode(
            PublicGameSnapshot.self,
            from: ContractJSON.encode(value)
        )
        return .snapshot(snapshot)
    }

    private func updateQuestionPresentationVersion(
        in object: inout [String: JSONValue],
        scenarioSteps: Int
    ) throws {
        guard case var .object(presentations)? = object["questionPresentation"] else {
            return
        }
        for key in presentations.keys {
            guard case var .object(presentation)? = presentations[key] else {
                throw TestFailure()
            }
            presentation["questionVersion"] = .number(.integer(Int64(scenarioSteps)))
            presentations[key] = .object(presentation)
        }
        object["questionPresentation"] = .object(presentations)
    }

    private func appendFutureNestedMessage(
        in object: inout [String: JSONValue]
    ) throws {
        guard case var .object(questions)? = object["question"] else {
            throw TestFailure()
        }
        let owner = try #require(questions.keys.first)
        guard case var .object(question)? = questions[owner] else { throw TestFailure() }
        guard case var .array(choices)? = question["choices"] else { throw TestFailure() }
        guard case var .object(firstChoice) = choices.first else { throw TestFailure() }
        guard case var .array(messages)? = firstChoice["messages"] else {
            throw TestFailure()
        }
        messages.append(.object(["tag": .string("FutureNestedMessage")]))
        firstChoice["messages"] = .array(messages)
        choices[0] = .object(firstChoice)
        question["choices"] = .array(choices)
        questions[owner] = .object(question)
        object["question"] = .object(questions)
    }

    private func replaceQuestionTag(
        in object: inout [String: JSONValue],
        with questionTag: String
    ) throws {
        guard case var .object(questions)? = object["question"] else {
            throw TestFailure()
        }
        let owner = try #require(questions.keys.first)
        guard case var .object(question)? = questions[owner] else { throw TestFailure() }
        question["tag"] = .string(questionTag)
        questions[owner] = .object(question)
        object["question"] = .object(questions)
        useLegacyQuestionFallback(in: &object)
    }
}
