@testable import ArkhamHorrorShared
import Foundation

struct GatheringTerminalContinuationInput {
    let branch: GatheringMovementEntryBranch
    let q42Prompt: BasicChoicePromptPresentation
    let q42Projection: BoardProjection
    let q42Authority: AssignmentReplayAuthoritativeObservation
    let precedingAnswers: [BasicChoiceAnswer]
    let context: ProductionGatheringActReplayRunner
        .MovementEntryExecutionContext
}

@MainActor
extension ProductionGatheringActReplayRunner {
    // swiftlint:disable:next function_body_length
    static func runTerminalContinuationIfNeeded(
        input: GatheringTerminalContinuationInput
    ) async throws -> GatheringTerminalReplayEvidence? {
        guard input.branch == .attic else { return nil }

        let context = input.context
        var projection = input.q42Projection
        var authority = input.q42Authority
        var answers = input.precedingAnswers
        var steps: [GatheringTerminalReplayStepEvidence] = []
        var defeatState: GatheringTerminalStateEvidence?
        var terminalState: GatheringTerminalStateEvidence?

        for expectation in GatheringTerminalRouteStep.attic {
            let prompt = try terminalPrompt(
                expectation: expectation,
                input: input
            )
            try validatePromptIdentity(
                prompt,
                projection: projection,
                version: expectation.questionVersion,
                configuration: context.configuration
            )
            let selectedSourceIndex = try terminalSourceIndex(
                role: expectation.role,
                prompt: prompt,
                projection: projection,
                investigatorID:
                context.configuration.promptIdentity.investigatorID
            )
            let promptEvidence = try GatheringActReplayPromptEvidence(
                prompt: prompt,
                projection: projection,
                selectedSourceIndex: selectedSourceIndex
            )
            if expectation.role == .resolveTreacheryForcedAbility {
                guard let treacheryIDText =
                    promptEvidence.selectedDescriptor?.entityID,
                    let treacheryID = TreacheryID(
                        codingKey: AnyCodingKey(
                            stringValue: treacheryIDText
                        )
                    )
                else {
                    throw ProductionGatheringActReplayError
                        .promptShapeMismatch
                }

                defeatState = try GatheringTerminalStateEvidence(
                    observation: authority,
                    investigatorID:
                    context.configuration.promptIdentity.investigatorID,
                    coverUpTreacheryID: treacheryID
                )
            }

            let answer = BasicChoiceAnswer(
                choice: selectedSourceIndex,
                playerID: context.configuration.promptIdentity.ownerID,
                questionVersion: expectation.questionVersion
            )
            let controller = try await executeController(
                prompt: prompt,
                projection: projection,
                selectedSourceIndex: selectedSourceIndex,
                model: context.model
            )
            try validateSubmission(controller.result)
            answers.append(answer)
            try validateSentAnswers(
                context.socketRecorder.snapshot(),
                expected: answers
            )
            try steps.append(
                GatheringTerminalReplayStepEvidence(
                    role: expectation.role,
                    prompt: promptEvidence,
                    answer: GatheringActReplayAnswerEvidence(
                        answer: answer
                    ),
                    controller: controller.evidence
                )
            )

            if expectation.questionVersion == 70 {
                projection = try await waitForTerminalProjection(
                    model: context.model,
                    configuration: context.configuration
                )
                authority = try await requireAuthority(
                    recorder: context.authoritativeRecorder,
                    projection: projection,
                    version: 70,
                    source: .socket,
                    configuration: context.configuration
                )
                try validateParticipant(
                    model: context.model,
                    configuration: context.configuration
                )
                guard context.model.basicChoicePresentation(
                    for: context.configuration.promptIdentity.gameID
                ) == nil
                else {
                    throw ProductionGatheringActReplayError
                        .promptShapeMismatch
                }
                terminalState = try GatheringTerminalStateEvidence(
                    observation: authority,
                    investigatorID:
                    context.configuration.promptIdentity.investigatorID,
                    coverUpTreacheryID: nil
                )
                break
            }

            projection = try await waitForProjection(
                model: context.model,
                version: expectation.questionVersion + 1,
                configuration: context.configuration
            )
            authority = try await requireAuthority(
                recorder: context.authoritativeRecorder,
                projection: projection,
                version: expectation.questionVersion + 1,
                source: .socket,
                configuration: context.configuration
            )
            try validateParticipant(
                model: context.model,
                configuration: context.configuration
            )
        }

        guard let defeatState, let terminalState else {
            throw ProductionGatheringActReplayError.promptShapeMismatch
        }
        let evidence = GatheringTerminalReplayEvidence(
            steps: steps,
            defeatState: defeatState,
            terminalState: terminalState
        )
        try evidence.validate(
            promptIdentity: GatheringReplayStateIdentity(
                gameID: context.configuration.promptIdentity.gameID,
                investigatorID:
                context.configuration.promptIdentity.investigatorID,
                gameRevision: context.configuration.attestation.gameRevision
            ),
            playerID: context.configuration.promptIdentity.ownerID
        )
        return evidence
    }

    private static func terminalPrompt(
        expectation: GatheringTerminalRouteStep,
        input: GatheringTerminalContinuationInput
    ) throws -> BasicChoicePromptPresentation {
        let isInitialPrompt =
            expectation.questionVersion ==
            ProductionGatheringActReplayConfiguration
            .resultingContinuationQuestionVersion
        if isInitialPrompt {
            return input.q42Prompt
        }
        return try requirePrompt(
            model: input.context.model,
            configuration: input.context.configuration
        )
    }

    private static func terminalSourceIndex(
        role: GatheringTerminalChoiceRole,
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection,
        investigatorID: InvestigatorID
    ) throws -> Int {
        guard prompt.canSubmit,
              let semantic = prompt.semanticPresentation
        else {
            throw ProductionGatheringActReplayError.promptShapeMismatch
        }
        try validateTerminalRawContext(
            role: role,
            rawQuestion: prompt.identity.rawQuestion
        )
        let matching = semantic.presentation.choices.filter {
            role.matches(
                GatheringActReplayDescriptorEvidence(choice: $0),
                investigatorID: investigatorID
            )
        }
        let descriptor: QuestionPresentation.Choice
        if role == .discardHandCard {
            guard let first = matching.min(by: {
                $0.sourceIndex < $1.sourceIndex
            }) else {
                throw ProductionGatheringActReplayError.promptShapeMismatch
            }
            descriptor = first
        } else {
            guard matching.count == 1, let only = matching.first else {
                throw ProductionGatheringActReplayError.promptShapeMismatch
            }
            descriptor = only
        }
        guard let choice = prompt.choices.first(where: {
            $0.index == descriptor.sourceIndex
        }),
            prompt.isChoiceActionable(choice, in: projection)
        else {
            throw ProductionGatheringActReplayError.promptShapeMismatch
        }
        return descriptor.sourceIndex
    }

    private static func validateTerminalRawContext(
        role: GatheringTerminalChoiceRole,
        rawQuestion: JSONValue
    ) throws {
        guard case let .object(object) = rawQuestion,
              case let .string(tag)? = object["tag"],
              tag == role.expectedRawTag
        else {
            throw ProductionGatheringActReplayError.promptShapeMismatch
        }
        switch role {
        case .addCampaignCardToDeck:
            guard case .string("c01117")? = object["card"],
                  case let .string(label)? = object["label"],
                  label.hasPrefix("$label.addCardToDeck ")
            else {
                throw ProductionGatheringActReplayError
                    .promptShapeMismatch
            }
        case .continueReading:
            guard object["readChoices"] != nil else {
                throw ProductionGatheringActReplayError
                    .promptShapeMismatch
            }
        default:
            break
        }
    }

    private static func waitForTerminalProjection(
        model: AppModel,
        configuration: ProductionGatheringActReplayConfiguration
    ) async throws -> BoardProjection {
        while true {
            _ = try configuration.deadline.remainingSeconds()
            switch model.liveGameState(
                for: configuration.promptIdentity.gameID
            ) {
            case let .live(projection):
                let isTerminal =
                    projection.counters.scenarioSteps == 70
                        && projection.counters.gameStateSummary == "Over"
                        && projection.counters.pendingPromptCount == 0
                if isTerminal {
                    return projection
                }
                if projection.counters.scenarioSteps > 70 {
                    throw ProductionGatheringActReplayError
                        .promptVersionMismatch
                }
            case .offline, .incompatiblePayload, .authenticationExpired,
                 .terminalFailure:
                throw ProductionGatheringActReplayError.liveSessionFailed
            case .idle, .loading, .reconnecting:
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
