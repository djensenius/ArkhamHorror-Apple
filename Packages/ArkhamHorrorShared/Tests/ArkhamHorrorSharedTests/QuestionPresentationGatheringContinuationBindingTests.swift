@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Semantic Gathering continuation raw binding")
struct GatheringContinuationBindingTests {
    @Test("Q40 through Q42 controls bind exact raw actions")
    func continuationControlsBindExactRawActions() throws {
        try assertControlBinds(
            version: 40,
            questionKind: .chooseOne,
            rawKind: .chooseOne,
            rawChoice: startSkillTestRawChoice(),
            descriptor: .gatheringStartSkillTest
        )
        try assertControlBinds(
            version: 40,
            questionKind: .playerWindowChooseOne,
            rawKind: .playerWindowChooseOne,
            rawChoice: endTurnRawChoice(),
            descriptor: .gatheringEndTurn(sourceIndex: 0)
        )
        try assertControlBinds(
            version: 41,
            questionKind: .chooseOne,
            rawKind: .chooseOne,
            rawChoice: applySkillTestResultsRawChoice(),
            descriptor: .gatheringApplySkillTestResults
        )
        try assertControlBinds(
            version: 42,
            questionKind: .playerWindowChooseOne,
            rawKind: .playerWindowChooseOne,
            rawChoice: endTurnRawChoice(),
            descriptor: .gatheringEndTurn(sourceIndex: 0)
        )
    }

    @Test("Q40 and Q41 reject substituted raw actions")
    func startAndApplyControlsRejectSubstitution() throws {
        let startSkillTest = try controlPresentation(
            version: 40,
            questionKind: .chooseOne,
            descriptor: .gatheringStartSkillTest
        )
        assertActionWindowBindingFails(
            presentation: startSkillTest,
            rawQuestion: rawQuestion(
                kind: .chooseOne,
                choice: startSkillTestRawChoice(actorID: "c01002")
            ),
            expectedQuestionVersion: 40
        )

        let applyResults = try controlPresentation(
            version: 41,
            questionKind: .chooseOne,
            descriptor: .gatheringApplySkillTestResults
        )
        assertActionWindowBindingFails(
            presentation: applyResults,
            rawQuestion: rawQuestion(
                kind: .chooseOne,
                choice: startSkillTestRawChoice()
            ),
            expectedQuestionVersion: 41
        )
    }

    @Test("Q42 end turn rejects message and descriptor substitution")
    func endTurnRejectsSubstitution() throws {
        let endTurn = try controlPresentation(
            version: 42,
            questionKind: .playerWindowChooseOne,
            descriptor: .gatheringEndTurn(sourceIndex: 0)
        )
        assertActionWindowBindingFails(
            presentation: endTurn,
            rawQuestion: rawQuestion(
                kind: .playerWindowChooseOne,
                choice: endTurnRawChoice(messageActorID: "c01002")
            )
        )

        let substitutedPresentation = QuestionPresentation(
            protocolVersion: 1,
            questionVersion: 42,
            questionKind: .playerWindowChooseOne,
            choiceCount: 1,
            choices: [.gatheringStartSkillTest]
        )
        assertActionWindowBindingFails(
            presentation: substitutedPresentation,
            rawQuestion: rawQuestion(
                kind: .playerWindowChooseOne,
                choice: endTurnRawChoice()
            )
        )
    }
}

private extension GatheringContinuationBindingTests {
    func assertControlBinds(
        version: Int,
        questionKind: QuestionPresentation.Kind,
        rawKind: BasicChoiceQuestionKind,
        rawChoice: JSONValue,
        descriptor: QuestionPresentation.Choice
    ) throws {
        let presentation = try controlPresentation(
            version: version,
            questionKind: questionKind,
            descriptor: descriptor
        )
        _ = try presentation.bind(
            to: rawQuestion(kind: rawKind, choice: rawChoice),
            expectedQuestionVersion: version
        )
    }

    func controlPresentation(
        version: Int,
        questionKind: QuestionPresentation.Kind,
        descriptor: QuestionPresentation.Choice
    ) throws -> QuestionPresentation {
        let presentation = QuestionPresentation(
            protocolVersion: 1,
            questionVersion: version,
            questionKind: questionKind,
            choiceCount: 1,
            choices: [descriptor]
        )
        return try ContractJSON.decode(
            QuestionPresentation.self,
            from: ContractJSON.encode(presentation)
        )
    }

    func rawQuestion(
        kind: BasicChoiceQuestionKind,
        choice: JSONValue
    ) -> JSONValue {
        .object([
            "choices": .array([choice]),
            "tag": .string(kind.rawValue),
        ])
    }

    func startSkillTestRawChoice(
        actorID: String = "c01001"
    ) -> JSONValue {
        .object([
            "investigatorId": .string(actorID),
            "tag": .string("StartSkillTestButton"),
        ])
    }

    func applySkillTestResultsRawChoice() -> JSONValue {
        .object([
            "tag": .string("SkillTestApplyResultsButton"),
        ])
    }

    func endTurnRawChoice(
        actorID: String = "c01001",
        messageActorID: String = "c01001"
    ) -> JSONValue {
        .object([
            "investigatorId": .string(actorID),
            "messages": .array([
                .object([
                    "contents": .string(messageActorID),
                    "tag": .string("ChooseEndTurn"),
                ]),
            ]),
            "tag": .string("EndTurnButton"),
        ])
    }
}
