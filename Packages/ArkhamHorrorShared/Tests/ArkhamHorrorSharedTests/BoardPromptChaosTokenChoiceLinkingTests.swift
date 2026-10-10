@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("BoardPromptChoiceLinker — chaos token targets")
struct BoardPromptChaosTokenChoiceLinkingTests {
    private let playerID = BoardTestFixtures.playerID("000000000801")
    @Test("Chaos-token target labels use the first matching focused token choice")
    func chaosTokenTargetLabelsUseFirstMatchingChoice() {
        let plusOneA = chaosToken(.plusOne)
        let plusOneB = chaosToken(.plusOne)
        let skull = chaosToken(.skull)
        let projection = chaosTokenProjection(
            bagTokens: [plusOneA, plusOneB, skull],
            focusedTokens: [plusOneA, plusOneB, skull]
        )
        let prompt = chaosTokenPrompt(targets: [
            chaosTokenFaceTarget(.plusOne),
            chaosTokenFaceTarget(.plusOne),
            chaosTokenFaceTarget(.skull),
            chaosTokenFaceTarget(.plusOne),
        ])
        let links = BoardPromptChoiceLinker.links(prompt: prompt, projection: projection)

        #expect(prompt.displayOrderedChoices(in: projection).isEmpty)
        #expect(links[.chaosToken(plusOneA.chaosTokenID)]?.map(\.choiceIndex) == [0])
        #expect(links[.chaosToken(plusOneB.chaosTokenID)]?.map(\.choiceIndex) == [0])
        #expect(links[.chaosToken(skull.chaosTokenID)]?.map(\.choiceIndex) == [2])
    }

    @Test("Chaos-token targets require the web TargetLabel choice type")
    func chaosTokenTargetsRequireTargetLabelChoiceType() {
        let token = chaosToken(.skull)
        let projection = chaosTokenProjection(bagTokens: [token], focusedTokens: [token])
        let prompt = chaosTokenPrompt(
            descriptors: [QuestionPresentation.Choice(
                sourceIndex: 0,
                kind: .opaque,
                uiTag: "NotTargetLabel",
                target: chaosTokenTarget(token)
            )]
        )

        #expect(prompt.displayOrderedChoices(in: projection).map(\.index) == [0])
        #expect(BoardPromptChoiceLinker.links(prompt: prompt, projection: projection).isEmpty)
    }

    @Test("Cancelled focused chaos tokens are hidden but not linked")
    func cancelledFocusedChaosTokensAreNotLinked() {
        let token = chaosToken(.skull, cancelled: true)
        let projection = chaosTokenProjection(bagTokens: [token], focusedTokens: [token])
        let prompt = chaosTokenPrompt(targets: [chaosTokenTarget(token)])

        #expect(prompt.displayOrderedChoices(in: projection).isEmpty)
        #expect(BoardPromptChoiceLinker.links(prompt: prompt, projection: projection).isEmpty)
    }

    @Test("Chaos-token group choices use the first matching focused token choice")
    func chaosTokenGroupChoicesUseFirstMatchingChoice() {
        let plusOne = chaosToken(.plusOne)
        let skull = chaosToken(.skull)
        let projection = chaosTokenProjection(
            bagTokens: [plusOne, skull],
            focusedTokens: [plusOne, skull]
        )
        let prompt = chaosTokenPrompt(descriptors: [
            QuestionPresentation.Choice(
                sourceIndex: 0,
                kind: .chaosTokenGroupChoice,
                step: chaosTokenGroupStep(tokens: [plusOne])
            ),
            QuestionPresentation.Choice(
                sourceIndex: 1,
                kind: .chaosTokenGroupChoice,
                step: chaosTokenGroupStep(tokens: [plusOne, skull])
            ),
        ])
        let links = BoardPromptChoiceLinker.links(prompt: prompt, projection: projection)

        #expect(links[.chaosToken(plusOne.chaosTokenID)]?.map(\.choiceIndex) == [0])
        #expect(links[.chaosToken(skull.chaosTokenID)]?.map(\.choiceIndex) == [1])
    }

    private func chaosTokenPrompt(targets: [JSONValue]) -> BasicChoicePromptPresentation {
        chaosTokenPrompt(descriptors: targets.enumerated().map { index, target in
            QuestionPresentation.Choice(
                sourceIndex: index,
                kind: .opaque,
                uiTag: "TargetLabel",
                target: target
            )
        })
    }

    private func chaosTokenPrompt(
        descriptors: [QuestionPresentation.Choice]
    ) -> BasicChoicePromptPresentation {
        let choices = descriptors.map { descriptor in
            BasicChoice(
                index: descriptor.sourceIndex,
                rawValue: rawChoice(tag: descriptor.uiTag ?? descriptor.kind.rawValue),
                content: .unsupported(tag: descriptor.uiTag ?? descriptor.kind.rawValue)
            )
        }
        return prompt(
            choices: choices,
            semanticPresentation: BoundQuestionPresentation(
                presentation: QuestionPresentation(
                    protocolVersion: QuestionPresentation.supportedProtocolVersion,
                    questionVersion: 1,
                    questionKind: .chooseOne,
                    choiceCount: choices.count,
                    choices: descriptors
                ),
                rawChoices: choices.map(\.rawValue)
            )
        )
    }

    private func chaosTokenProjection(
        bagTokens: [ChaosToken],
        focusedTokens: [ChaosToken]
    ) -> BoardProjection {
        BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            mode: .scenarioOnly(BoardTestFixtures.scenario(
                chaosBag: BoardTestFixtures.chaosBag(chaosTokens: bagTokens)
            )),
            focusedChaosTokens: focusedTokens.map(chaosTokenValue)
        ))
    }

    private func chaosToken(_ face: ChaosTokenFace, cancelled: Bool = false) -> ChaosToken {
        ChaosToken(
            chaosTokenID: Identifier(UUID()),
            chaosTokenFace: face,
            chaosTokenRevealedBy: nil,
            chaosTokenCancelled: cancelled,
            chaosTokenSealed: false
        )
    }

    private func chaosTokenFaceTarget(_ face: ChaosTokenFace) -> JSONValue {
        .object([
            "tag": .string("ChaosTokenFaceTarget"),
            "contents": .string(face.rawValue),
        ])
    }

    private func chaosTokenTarget(_ token: ChaosToken) -> JSONValue {
        .object([
            "tag": .string("ChaosTokenTarget"),
            "contents": chaosTokenReference(token),
        ])
    }

    private func chaosTokenGroupStep(tokens: [ChaosToken]) -> JSONValue {
        .object([
            "tokenGroups": .array([.array(tokens.map { chaosTokenReference($0) })]),
        ])
    }

    private func chaosTokenValue(_ token: ChaosToken) -> JSONValue {
        .object([
            "chaosTokenId": .string(token.chaosTokenID.codingKey.stringValue),
            "chaosTokenFace": .string(token.chaosTokenFace.rawValue),
            "chaosTokenRevealedBy": .null,
            "chaosTokenCancelled": .bool(token.chaosTokenCancelled),
            "chaosTokenSealed": .bool(token.chaosTokenSealed),
        ])
    }

    private func chaosTokenReference(_ token: ChaosToken) -> JSONValue {
        .object([
            "id": .string(token.chaosTokenID.codingKey.stringValue),
            "face": .string(token.chaosTokenFace.rawValue),
        ])
    }

    private func rawChoice(tag: String) -> JSONValue {
        .object(["tag": .string(tag)])
    }

    private func prompt(
        choices: [BasicChoice],
        semanticPresentation: BoundQuestionPresentation
    ) -> BasicChoicePromptPresentation {
        let rawQuestion: JSONValue = .object([
            "tag": .string(BasicChoiceQuestionKind.chooseOne.rawValue),
            "choices": .array(choices.map(\.rawValue)),
        ])
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: playerID,
                questionVersion: 1,
                rawQuestion: rawQuestion,
                questionPresentation: semanticPresentation.presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: .supported(BasicChoiceQuestion(
                kind: .chooseOne,
                choices: choices,
                story: nil,
                rawValue: rawQuestion
            )),
            semanticPresentation: semanticPresentation,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }
}
