@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Standalone settings prompt")
struct StandaloneSettingsPromptTests {
    @Test("Captured PickScenarioSettings prompt is renderable and answerable")
    func capturedPickScenarioSettingsPromptIsRenderable() throws {
        let fixture = try Self.fixture(named: "pick-scenario-settings")
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: ContractJSON.encode(fixture.rawQuestion)
        )
        let binding = try fixture.questionPresentation.bind(
            to: fixture.rawQuestion,
            expectedQuestionVersion: fixture.questionVersion
        )
        let prompt = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: fixture.questionVersion,
                rawQuestion: fixture.rawQuestion,
                questionPresentation: binding.presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            semanticPresentation: binding,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )

        #expect(prompt.isRenderableQuestion)
        #expect(prompt.isStandaloneSettingsPrompt)
        #expect(prompt.canSubmit)
        #expect(prompt.supportsStandaloneSettingsSubmission([]))
        #expect(!prompt.supportsStandaloneSettingsSubmission([.string("unexpected")]))
    }

    @Test("Captured Laid to Rest scenario-specific prompt derives exact default answer")
    func laidToRestScenarioSpecificDefaultAnswerBytes() throws {
        let fixture = try Self.fixture(named: "pick-scenario-specific-laid-to-rest")
        let binding = try fixture.questionPresentation.bind(
            to: fixture.rawQuestion,
            expectedQuestionVersion: fixture.questionVersion
        )
        let prompt = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: fixture.questionVersion,
                rawQuestion: fixture.rawQuestion,
                questionPresentation: binding.presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: .updateRequired(tag: "PickScenarioSpecific"),
            semanticPresentation: binding,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )

        let answer = try #require(prompt.scenarioSpecificDefaultAnswer)
        #expect(prompt.isRenderableQuestion)
        #expect(prompt.canSubmit)
        #expect(prompt.supportsScenarioSpecificSubmission(answer))
        let encoded = try ContractJSON.encode(ScenarioSpecificAnswer(contents: answer))
        let encodedString = try #require(String(data: encoded, encoding: .utf8))
        // swiftlint:disable:next line_length
        let expected = #"{"contents":["laidToRest.buildSpiritDeck",{"cardCodes":["c05151","c01018","c12016","c02106","c09033","c60107","c01021","c12018","c60156"]}],"tag":"ScenarioSpecificAnswer"}"#
        #expect(encodedString == expected)
    }

    @Test("StandaloneSettingsAnswer empty settings encode exact server bytes")
    func emptyStandaloneSettingsAnswerBytes() throws {
        let encoded = try ContractJSON.encode(StandaloneSettingsAnswer(contents: []))
        let encodedString = try #require(String(data: encoded, encoding: .utf8))
        let expected = #"{"contents":[],"tag":"StandaloneSettingsAnswer"}"#
        #expect(encodedString == expected)
        let decoded = try ContractJSON.decode(StandaloneSettingsAnswer.self, from: encoded)
        #expect(decoded == StandaloneSettingsAnswer(contents: []))
    }

    private static func fixture(named name: String) throws -> CapturedPromptFixture {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/LiveStandaloneSettingsPrompt"
        ))
        return try ContractJSON.decode(CapturedPromptFixture.self, from: Data(contentsOf: url))
    }
}

private struct CapturedPromptFixture: Decodable {
    let questionVersion: Int
    let rawQuestion: JSONValue
    let questionPresentation: QuestionPresentation
}
