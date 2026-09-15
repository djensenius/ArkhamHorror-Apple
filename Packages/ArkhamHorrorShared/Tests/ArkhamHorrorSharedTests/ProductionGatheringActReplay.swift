@testable import ArkhamHorrorShared
import Foundation

// swiftlint:disable file_length

enum ProductionGatheringActReplayError: Error, Equatable {
    case assetPipelineUnavailable
    case sessionNotSignedIn
    case sessionPlayerIdentityMismatch
    case serverNotModern
    case serverContractRevisionMismatch
    case serverAttestationMismatch
    case catalogAdvertisementMismatch
    case catalogSnapshotMismatch
    case storyAssetSourceUnavailable
    case liveSessionFailed
    case authoritativeObservationMissing
    case authoritativeGameIdentityMismatch
    case authoritativePlayerIdentityMismatch
    case authoritativeGameRevisionMismatch
    case authoritativeProjectionMismatch
    case promptMissing
    case promptIdentityMismatch
    case promptVersionMismatch
    case promptShapeMismatch
    case controllerJumpRejected
    case controllerMoveRejected
    case controllerFocusMismatch
    case controllerPrimaryActionRejected
    case controllerSubmissionMissing
    case controllerSourceIndexMismatch
    case answerSubmissionFailed
    case sentAnswerCountMismatch
    case sentAnswerMismatch
}

private struct GatheringActReplayControllerExecution {
    let evidence: GatheringActReplayControllerEvidence
    let result: BasicChoiceSubmitResult
}

@MainActor
// swiftlint:disable:next type_body_length
enum ProductionGatheringActReplayRunner {
    // swiftlint:disable:next function_body_length
    static func run(
        configuration: ProductionGatheringActReplayConfiguration
    ) async throws -> ProductionGatheringActReplayEvidence {
        _ = try configuration.deadline.remainingSeconds()
        let capabilityTransport = try AssignmentReplayCapabilityTransport(
            base: AssignmentReplayBoundedHTTPTransport(
                maxByteCount:
                AssignmentReplayCapabilityTransport.maximumResponseBytes,
                deadline: configuration.deadline
            )
        )
        let authenticationTransport =
            try AssignmentReplayBoundedHTTPTransport(
                maxByteCount: AssignmentReplayBootstrapLimits
                    .maximumAuthenticationResponseBytes,
                deadline: configuration.deadline
            )
        let localeTransport = ReplayDeadlineLocaleTransport(
            deadline: configuration.deadline
        )
        let socketRecorder = ProductionAssignmentReplaySocketRecorder()
        let authoritativeRecorder = AssignmentReplayAuthoritativeRecorder()
        let gameTransport = try AssignmentReplayRecordingGameTransport(
            base: AssignmentReplayBoundedHTTPTransport(
                maxByteCount:
                ProductionAssignmentReplayBackend.maximumGameResponseBytes,
                deadline: configuration.deadline
            ),
            recorder: authoritativeRecorder
        )
        let socketFactory = AssignmentReplayRecordingSocketFactory(
            base: AssignmentReplayDeadlineSocketFactory(
                deadline: configuration.deadline
            ),
            recorder: socketRecorder,
            authoritativeRecorder: authoritativeRecorder
        )
        guard let assetCache = AssetCacheService.production() else {
            throw ProductionGatheringActReplayError.assetPipelineUnavailable
        }
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [configuration.serverProfile],
                selectedID: configuration.serverProfile.id
            ),
            tokenStore: FakeTokenStore(tokens: [
                configuration.serverProfile.id: configuration.authToken,
            ]),
            capabilityProbe: CapabilityProbe(transport: capabilityTransport),
            authenticationSession: AuthenticationSession(
                transport: authenticationTransport
            ),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: GameLifecycleService(
                transport: gameTransport
            ),
            liveGameSocketFactory: socketFactory,
            localeCatalogLoader: .production(transport: localeTransport),
            preferredLanguagesProvider: SystemPreferredLanguages(),
            assetCacheService: assetCache,
            assetCacheFactory: { assetCache },
            storyAssetSourceLoader: StoryAssetSourceLoader(
                transport: localeTransport
            )
        )
        defer {
            model.flowTask?.cancel()
            model.localeCatalogTask?.cancel()
        }

        await model.flowTask?.value
        _ = try configuration.deadline.remainingSeconds()
        let capabilities = try await validateBoot(
            model: model,
            capabilityTransport: capabilityTransport,
            configuration: configuration
        )
        if let catalogTask = model.localeCatalogTask {
            await catalogTask.value
        }
        _ = try configuration.deadline.remainingSeconds()
        try validateCatalogAndAssets(
            model: model,
            capabilities: capabilities,
            configuration: configuration
        )
        let attestationTransport =
            try AssignmentReplayBoundedHTTPTransport(
                maxByteCount:
                AssignmentReplayAttestationClient.maximumResponseBytes,
                deadline: configuration.deadline
            )
        let attestation = try await AssignmentReplayAttestationClient(
            transport: attestationTransport
        ).fetch(request: configuration.attestationRequest)
        guard attestation == configuration.attestation else {
            throw ProductionGatheringActReplayError
                .serverAttestationMismatch
        }

        let subscription = model.subscribeToLiveGame(
            configuration.promptIdentity.gameID
        )
        defer { model.unsubscribeFromLiveGame(subscription) }

        let q34Projection = try await waitForProjection(
            model: model,
            version:
            ProductionGatheringActReplayConfiguration.startingQuestionVersion,
            configuration: configuration
        )
        let q34Authority = try await requireAuthority(
            recorder: authoritativeRecorder,
            projection: q34Projection,
            version:
            ProductionGatheringActReplayConfiguration.startingQuestionVersion,
            source: .rest,
            configuration: configuration
        )
        try validateParticipant(model: model, configuration: configuration)
        let q34Prompt = try requirePrompt(
            model: model,
            configuration: configuration
        )
        let q34PromptEvidence = try GatheringActReplayPromptEvidence(
            prompt: q34Prompt,
            projection: q34Projection,
            selectedSourceIndex: 12
        )
        try validateQ34Prompt(
            q34Prompt,
            evidence: q34PromptEvidence,
            projection: q34Projection,
            configuration: configuration
        )
        let q34State = try GatheringActReplayBoardStateEvidence(
            observation: q34Authority,
            investigatorID: configuration.promptIdentity.investigatorID
        )
        let q34Answer = BasicChoiceAnswer(
            choice: 12,
            playerID: configuration.promptIdentity.ownerID,
            questionVersion:
            ProductionGatheringActReplayConfiguration.startingQuestionVersion
        )
        let q34Execution = try await executeController(
            prompt: q34Prompt,
            projection: q34Projection,
            selectedSourceIndex: 12,
            model: model
        )
        try validateSentAnswers(
            socketRecorder.snapshot(),
            expected: [q34Answer]
        )
        guard q34Execution.result == .sentAwaitingSnapshot ||
            q34Execution.result == .retryableFailure
        else {
            throw ProductionGatheringActReplayError.answerSubmissionFailed
        }

        let q35Projection = try await waitForProjection(
            model: model,
            version:
            ProductionGatheringActReplayConfiguration
                .confirmationQuestionVersion,
            configuration: configuration
        )
        _ = try await requireAuthority(
            recorder: authoritativeRecorder,
            projection: q35Projection,
            version:
            ProductionGatheringActReplayConfiguration
                .confirmationQuestionVersion,
            source: .socket,
            configuration: configuration
        )
        try validateParticipant(model: model, configuration: configuration)
        let q35Prompt = try requirePrompt(
            model: model,
            configuration: configuration
        )
        let q35PromptEvidence = try GatheringActReplayPromptEvidence(
            prompt: q35Prompt,
            projection: q35Projection,
            selectedSourceIndex: 0
        )
        try validateQ35Prompt(
            q35Prompt,
            evidence: q35PromptEvidence,
            projection: q35Projection,
            configuration: configuration
        )
        let q35Answer = BasicChoiceAnswer(
            choice: 0,
            playerID: configuration.promptIdentity.ownerID,
            questionVersion:
            ProductionGatheringActReplayConfiguration
                .confirmationQuestionVersion
        )
        let q35Execution = try await executeController(
            prompt: q35Prompt,
            projection: q35Projection,
            selectedSourceIndex: 0,
            model: model
        )
        try validateSentAnswers(
            socketRecorder.snapshot(),
            expected: [q34Answer, q35Answer]
        )
        guard q35Execution.result == .sentAwaitingSnapshot ||
            q35Execution.result == .retryableFailure
        else {
            throw ProductionGatheringActReplayError.answerSubmissionFailed
        }

        let q36Projection = try await waitForProjection(
            model: model,
            version:
            ProductionGatheringActReplayConfiguration
                .resultingQuestionVersion,
            configuration: configuration
        )
        let q36Authority = try await requireAuthority(
            recorder: authoritativeRecorder,
            projection: q36Projection,
            version:
            ProductionGatheringActReplayConfiguration
                .resultingQuestionVersion,
            source: .socket,
            configuration: configuration
        )
        try validateParticipant(model: model, configuration: configuration)
        let q36Prompt = try requirePrompt(
            model: model,
            configuration: configuration
        )
        let q36PromptEvidence = try GatheringActReplayPromptEvidence(
            prompt: q36Prompt,
            projection: q36Projection,
            selectedSourceIndex: nil
        )
        try validateQ36Prompt(
            q36Prompt,
            evidence: q36PromptEvidence,
            projection: q36Projection,
            configuration: configuration
        )
        let q36State = try GatheringActReplayBoardStateEvidence(
            observation: q36Authority,
            investigatorID: configuration.promptIdentity.investigatorID
        )

        let evidence = try ProductionGatheringActReplayEvidence(
            schemaVersion:
            ProductionGatheringActReplayEvidence.currentSchemaVersion,
            attestation: attestation,
            gameID: configuration.promptIdentity.gameID,
            playerID: configuration.promptIdentity.ownerID,
            investigatorID: configuration.promptIdentity.investigatorID,
            q34Prompt: q34PromptEvidence,
            q34Answer: GatheringActReplayAnswerEvidence(
                answer: q34Answer
            ),
            q34Controller: q34Execution.evidence,
            q34State: q34State,
            q35Prompt: q35PromptEvidence,
            q35Answer: GatheringActReplayAnswerEvidence(
                answer: q35Answer
            ),
            q35Controller: q35Execution.evidence,
            q36Prompt: q36PromptEvidence,
            q36State: q36State,
            revisions: AssignmentReplayRevisionEvidence(
                serverBuild: attestation.serverBuild,
                game: attestation.gameRevision,
                apple: configuration.expectedAppleRevision,
                contract: configuration.expectedContractRevision,
                catalog: configuration.expectedCatalogRevision
            )
        )
        try evidence.validate(
            configuration: configuration,
            attestation: attestation
        )
        try validateSentAnswers(
            socketRecorder.snapshot(),
            expected: [q34Answer, q35Answer]
        )
        return evidence
    }

    private static func validateBoot(
        model: AppModel,
        capabilityTransport: AssignmentReplayCapabilityTransport,
        configuration: ProductionGatheringActReplayConfiguration
    ) async throws -> ServerCapabilities {
        guard case let .signedIn(profile, compatibility, _) =
            model.sessionState,
            profile == configuration.serverProfile
        else {
            throw ProductionGatheringActReplayError.sessionNotSignedIn
        }
        guard case let .modern(sessionCapabilities) = compatibility else {
            throw ProductionGatheringActReplayError.serverNotModern
        }
        let serverCapabilities =
            try await capabilityTransport.decodedCapabilities()
        guard serverCapabilities.capabilities == sessionCapabilities,
              serverCapabilities.schemaRevision ==
              configuration.expectedContractRevision,
              serverCapabilities.apiBasePath ==
              ContractPin.current.expectedApiBasePath
        else {
            throw ProductionGatheringActReplayError
                .serverContractRevisionMismatch
        }
        guard serverCapabilities.localeCatalog?.catalogRevision ==
            configuration.expectedCatalogRevision
        else {
            throw ProductionGatheringActReplayError
                .catalogAdvertisementMismatch
        }
        return serverCapabilities
    }

    private static func validateCatalogAndAssets(
        model: AppModel,
        capabilities: ServerCapabilities,
        configuration: ProductionGatheringActReplayConfiguration
    ) throws {
        guard let advertisement = capabilities.localeCatalog,
              advertisement.catalogRevision ==
              configuration.expectedCatalogRevision,
              model.localeCatalogRequest == LocaleCatalogRequest(
                  profileID: configuration.serverProfile.id,
                  advertisement: advertisement
              ),
              model.localeCatalog?.identity.catalogRevision ==
              configuration.expectedCatalogRevision
        else {
            throw ProductionGatheringActReplayError.catalogSnapshotMismatch
        }
        guard model.assetCacheService != nil,
              model.storyAssetSource != nil,
              model.storyAssetSourceFailure == nil
        else {
            throw ProductionGatheringActReplayError
                .storyAssetSourceUnavailable
        }
    }

    private static func waitForProjection(
        model: AppModel,
        version: Int,
        configuration: ProductionGatheringActReplayConfiguration
    ) async throws -> BoardProjection {
        while true {
            _ = try configuration.deadline.remainingSeconds()
            switch model.liveGameState(
                for: configuration.promptIdentity.gameID
            ) {
            case let .live(projection)
                where projection.counters.scenarioSteps == version:
                return projection
            case let .live(projection)
                where projection.counters.scenarioSteps > version:
                throw ProductionGatheringActReplayError.promptVersionMismatch
            case .offline, .incompatiblePayload, .authenticationExpired,
                 .terminalFailure:
                throw ProductionGatheringActReplayError.liveSessionFailed
            case .idle, .loading, .live, .reconnecting:
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func requireAuthority(
        recorder: AssignmentReplayAuthoritativeRecorder,
        projection: BoardProjection,
        version: Int,
        source: AssignmentReplayObservationSource,
        configuration: ProductionGatheringActReplayConfiguration
    ) async throws -> AssignmentReplayAuthoritativeObservation {
        guard let observation = await recorder.latest(
            gameID: configuration.promptIdentity.gameID,
            questionVersion: version,
            source: source
        ) else {
            throw ProductionGatheringActReplayError
                .authoritativeObservationMissing
        }
        guard observation.gameID == configuration.promptIdentity.gameID,
              observation.snapshot.id ==
              configuration.promptIdentity.gameID
        else {
            throw ProductionGatheringActReplayError
                .authoritativeGameIdentityMismatch
        }
        guard observation.gameRevision ==
            configuration.attestation.gameRevision,
            observation.snapshot.git ==
            configuration.attestation.gameRevision
        else {
            throw ProductionGatheringActReplayError
                .authoritativeGameRevisionMismatch
        }
        if source == .rest || observation.playerID != nil {
            guard observation.playerID ==
                configuration.promptIdentity.ownerID
            else {
                throw ProductionGatheringActReplayError
                    .authoritativePlayerIdentityMismatch
            }
        }
        guard observation.projection == projection else {
            throw ProductionGatheringActReplayError
                .authoritativeProjectionMismatch
        }
        return observation
    }

    private static func validateParticipant(
        model: AppModel,
        configuration: ProductionGatheringActReplayConfiguration
    ) throws {
        guard model.liveGameParticipantIdentities[
            configuration.promptIdentity.gameID
        ] == .participant(configuration.promptIdentity.ownerID)
        else {
            throw ProductionGatheringActReplayError
                .sessionPlayerIdentityMismatch
        }
    }

    private static func requirePrompt(
        model: AppModel,
        configuration: ProductionGatheringActReplayConfiguration
    ) throws -> BasicChoicePromptPresentation {
        guard let prompt = model.basicChoicePresentation(
            for: configuration.promptIdentity.gameID
        ) else {
            throw ProductionGatheringActReplayError.promptMissing
        }
        return prompt
    }

    private static func validatePromptIdentity(
        _ prompt: BasicChoicePromptPresentation,
        projection: BoardProjection,
        version: Int,
        configuration: ProductionGatheringActReplayConfiguration
    ) throws {
        guard prompt.identity.gameID ==
            configuration.promptIdentity.gameID,
            prompt.ownerID == configuration.promptIdentity.ownerID,
            prompt.identity.sessionAttemptID != nil,
            prompt.identity.connectionID != nil
        else {
            throw ProductionGatheringActReplayError.promptIdentityMismatch
        }
        guard prompt.questionVersion == version,
              projection.counters.scenarioSteps == version,
              projection.questions.count == 1,
              projection.questions[
                  configuration.promptIdentity.ownerID
              ]?.rawValue == prompt.identity.rawQuestion
        else {
            throw ProductionGatheringActReplayError.promptVersionMismatch
        }
    }

    private static func validateQ34Prompt(
        _ prompt: BasicChoicePromptPresentation,
        evidence: GatheringActReplayPromptEvidence,
        projection: BoardProjection,
        configuration: ProductionGatheringActReplayConfiguration
    ) throws {
        try validatePromptIdentity(
            prompt,
            projection: projection,
            version:
            ProductionGatheringActReplayConfiguration.startingQuestionVersion,
            configuration: configuration
        )
        let descriptor = evidence.selectedDescriptor
        guard evidence.canonicalSHA256 ==
            configuration.expectedPromptDigest,
            prompt.canSubmit,
            prompt.question.supportedQuestion?.kind ==
            .playerWindowChooseOne,
            evidence.choiceCount == 13,
            evidence.sourceIndices == Array(0 ... 12),
            evidence.actionableSourceIndices.first == 0,
            evidence.actionableSourceIndices.last == 12,
            evidence.actionableSourceIndices ==
            evidence.actionableSourceIndices.sorted(),
            Set(evidence.actionableSourceIndices).count ==
            evidence.actionableSourceIndices.count,
            descriptor?.kind ==
            QuestionPresentation.ChoiceKind.advanceAct.rawValue,
            descriptor?.actorID ==
            configuration.promptIdentity.investigatorID.codingKey.stringValue,
            descriptor?.entityID ==
            ProductionGatheringActReplayConfiguration.advancingActID,
            descriptor?.costKind == "groupClue",
            descriptor?.costAmountKind == "perPlayer",
            descriptor?.costAmountValue == 2,
            descriptor?.costScope == "anywhere"
        else {
            throw ProductionGatheringActReplayError.promptShapeMismatch
        }
    }

    private static func validateQ35Prompt(
        _ prompt: BasicChoicePromptPresentation,
        evidence: GatheringActReplayPromptEvidence,
        projection: BoardProjection,
        configuration: ProductionGatheringActReplayConfiguration
    ) throws {
        try validatePromptIdentity(
            prompt,
            projection: projection,
            version:
            ProductionGatheringActReplayConfiguration
                .confirmationQuestionVersion,
            configuration: configuration
        )
        let descriptor = evidence.selectedDescriptor
        guard prompt.canSubmit,
              prompt.question.supportedQuestion?.kind == .chooseOne,
              evidence.choiceCount == 1,
              evidence.sourceIndices == [0],
              evidence.actionableSourceIndices == [0],
              descriptor?.kind ==
              QuestionPresentation.ChoiceKind.advanceAct.rawValue,
              descriptor?.actorID == nil,
              descriptor?.entityID ==
              ProductionGatheringActReplayConfiguration.advancingActID,
              descriptor?.abilityCardCode == nil,
              descriptor?.costKind == nil
        else {
            throw ProductionGatheringActReplayError.promptShapeMismatch
        }
    }

    private static func validateQ36Prompt(
        _ prompt: BasicChoicePromptPresentation,
        evidence: GatheringActReplayPromptEvidence,
        projection: BoardProjection,
        configuration: ProductionGatheringActReplayConfiguration
    ) throws {
        try validatePromptIdentity(
            prompt,
            projection: projection,
            version:
            ProductionGatheringActReplayConfiguration
                .resultingQuestionVersion,
            configuration: configuration
        )
        try evidence.validateResultingPrompt()
        guard prompt.canSubmit else {
            throw ProductionGatheringActReplayError.promptShapeMismatch
        }
    }

    // swiftlint:disable:next function_body_length
    private static func executeController(
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection,
        selectedSourceIndex: Int,
        model: AppModel
    ) async throws -> GatheringActReplayControllerExecution {
        var submittedSourceIndex: Int?
        var submissionTask: Task<BasicChoiceSubmitResult, Never>?
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onChoice: { sourceIndex in
                submittedSourceIndex = sourceIndex
                submissionTask = Task {
                    await model.submitBasicChoice(
                        prompt.identity,
                        choiceIndex: sourceIndex
                    )
                }
            }
        )
        let jumpHandled = controller.handle(
            .command(.jumpToActivePrompt)
        )
        guard jumpHandled else {
            throw ProductionGatheringActReplayError
                .controllerJumpRejected
        }
        let focusAfterJump = controller.coordinator.currentFocus
        guard focusAfterJump == BoardFocusID.promptChoice(0) else {
            throw ProductionGatheringActReplayError.controllerFocusMismatch
        }
        var focusSourceIndices = [0]
        var allMovesHandled = true
        let selectedFocus = BoardFocusID.promptChoice(selectedSourceIndex)
        while controller.coordinator.currentFocus != selectedFocus {
            guard focusSourceIndices.count <= prompt.choices.count else {
                throw ProductionGatheringActReplayError
                    .controllerMoveRejected
            }
            let handled = controller.handle(
                .command(.focusMove(.down))
            )
            allMovesHandled = allMovesHandled && handled
            guard handled,
                  let focusedSourceIndex = prompt.choices.first(where: {
                      BoardFocusID.promptChoice($0.index) ==
                          controller.coordinator.currentFocus
                  })?.index,
                  !focusSourceIndices.contains(focusedSourceIndex)
            else {
                throw ProductionGatheringActReplayError
                    .controllerMoveRejected
            }
            focusSourceIndices.append(focusedSourceIndex)
        }
        let focusBeforePrimaryAction =
            controller.coordinator.currentFocus
        guard focusBeforePrimaryAction ==
            BoardFocusID.promptChoice(selectedSourceIndex)
        else {
            throw ProductionGatheringActReplayError.controllerFocusMismatch
        }
        let primaryActionHandled = controller.handle(
            .command(.primaryAction)
        )
        guard primaryActionHandled else {
            throw ProductionGatheringActReplayError
                .controllerPrimaryActionRejected
        }
        guard submittedSourceIndex == selectedSourceIndex else {
            throw ProductionGatheringActReplayError
                .controllerSourceIndexMismatch
        }
        guard let submissionTask else {
            throw ProductionGatheringActReplayError
                .controllerSubmissionMissing
        }
        let result = await submissionTask.value
        return GatheringActReplayControllerExecution(
            evidence: GatheringActReplayControllerEvidence(
                jumpHandled: jumpHandled,
                focusAfterJump: focusAfterJump?.rawValue ?? "",
                moveCount: focusSourceIndices.count - 1,
                allMovesHandled: allMovesHandled,
                focusSourceIndices: focusSourceIndices,
                focusBeforePrimaryAction:
                focusBeforePrimaryAction?.rawValue ?? "",
                primaryActionHandled: primaryActionHandled,
                selectedSourceIndex: selectedSourceIndex,
                submissionResult: submissionResultName(result)
            ),
            result: result
        )
    }

    private static func submissionResultName(
        _ result: BasicChoiceSubmitResult
    ) -> String {
        switch result {
        case .sentAwaitingSnapshot:
            "sentAwaitingSnapshot"
        case .alreadyPending:
            "alreadyPending"
        case .retryableFailure:
            "retryableFailure"
        case .staleQuestion:
            "staleQuestion"
        case .readOnly:
            "readOnly"
        case .unsupportedChoice:
            "unsupportedChoice"
        }
    }

    private static func validateSentAnswers(
        _ sentAnswers: [Data],
        expected answers: [BasicChoiceAnswer]
    ) throws {
        let expectedData = try answers.map(ContractJSON.encode)
        guard sentAnswers.count == expectedData.count else {
            throw ProductionGatheringActReplayError
                .sentAnswerCountMismatch
        }
        for index in sentAnswers.indices {
            let sent = sentAnswers[index]
            let expected = expectedData[index]
            let answer = answers[index]
            guard sent == expected,
                  try ContractJSON.decode(
                      BasicChoiceAnswer.self,
                      from: sent
                  ) == answer
            else {
                throw ProductionGatheringActReplayError.sentAnswerMismatch
            }
        }
    }
}
