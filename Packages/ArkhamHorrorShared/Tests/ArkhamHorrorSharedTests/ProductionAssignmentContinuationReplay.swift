@testable import ArkhamHorrorShared
import Foundation
import Testing

// swiftlint:disable file_length

enum ProductionAssignmentReplayError: Error, Equatable {
    case invalidCheckpointArtifact
    case appleRevisionUnavailable
    case appleSourceDirty
    case unsupportedHost
    case assetPipelineUnavailable
    case sessionNotSignedIn
    case sessionPlayerIdentityMismatch
    case serverNotModern
    case capabilitiesUnavailable
    case serverContractRevisionMismatch
    case serverAttestationUnavailable
    case serverAttestationMalformed
    case serverAttestationMismatch
    case catalogAdvertisementMismatch
    case catalogSnapshotMismatch
    case storyAssetSourceUnavailable
    case initialSnapshotTimedOut
    case nextSnapshotTimedOut
    case liveSessionFailed
    case startingAuthoritativeObservationMissing
    case nextAuthoritativeObservationMissing
    case authoritativeGameIdentityMismatch
    case authoritativePlayerIdentityMismatch
    case authoritativeGameRevisionMismatch
    case authoritativeProjectionMismatch
    case startingPromptMissing
    case startingPromptIdentityMismatch
    case startingPromptDigestMismatch
    case startingPromptVersionMismatch
    case startingPromptShapeMismatch
    case startingAssignmentMismatch
    case startingAssignmentFieldsMismatch
    case controllerJumpRejected
    case controllerFocusMismatch
    case controllerMoveRejected
    case controllerPrimaryActionRejected
    case controllerSubmissionMissing
    case controllerSourceIndexMismatch
    case answerSubmissionFailed
    case sentAnswerCountMismatch
    case sentAnswerMismatch
    case nextPromptMissing
    case nextPromptIdentityMismatch
    case nextPromptVersionMismatch
    case nextPromptShapeMismatch
    case nextAssignmentMismatch
    case nextAssignmentFieldsMismatch
    case assignmentDeltaMismatch
    case evidenceCheckpointMismatch
}

struct AssignmentReplayStartingObservation {
    let assignmentBefore: AssignmentReplayFields
    let promptDigest: String
}

struct AssignmentReplayNextObservation {
    let assignmentAfter: AssignmentReplayFields
    let promptDigest: String

    fileprivate init(
        assignmentAfter: AssignmentReplayFields,
        promptDigest: String
    ) {
        self.assignmentAfter = assignmentAfter
        self.promptDigest = promptDigest
    }
}

struct AssignmentReplayCanonicalSendProof: Sendable {
    fileprivate init() {}
}

enum AssignmentReplaySubmissionValidator {
    static func proveCanonicalSend(
        sentAnswers: [Data],
        expectedData: Data,
        expectedAnswer: BasicChoiceAnswer
    ) throws -> AssignmentReplayCanonicalSendProof {
        guard sentAnswers.count == 1 else {
            throw ProductionAssignmentReplayError.sentAnswerCountMismatch
        }
        guard sentAnswers[0] == expectedData,
              try ContractJSON.decode(
                  BasicChoiceAnswer.self,
                  from: sentAnswers[0]
              ) == expectedAnswer
        else {
            throw ProductionAssignmentReplayError.sentAnswerMismatch
        }
        return AssignmentReplayCanonicalSendProof()
    }

    static func validateResolvedSubmission(
        _ result: BasicChoiceSubmitResult,
        sendProof _: AssignmentReplayCanonicalSendProof,
        nextProof _: AssignmentReplayNextObservation
    ) throws {
        guard result == .sentAwaitingSnapshot ||
            result == .retryableFailure
        else {
            throw ProductionAssignmentReplayError.answerSubmissionFailed
        }
    }
}

enum AssignmentReplayAuthoritativeValidator {
    static func validate(
        _ observation: AssignmentReplayAuthoritativeObservation,
        projection: BoardProjection,
        configuration: ProductionAssignmentReplayConfiguration,
        attestation: ProductionAssignmentReplayAttestation,
        requiresPlayerIdentity: Bool
    ) throws {
        guard observation.gameID == configuration.promptIdentity.gameID else {
            throw ProductionAssignmentReplayError.authoritativeGameIdentityMismatch
        }
        guard observation.gameRevision == attestation.gameRevision
        else {
            throw ProductionAssignmentReplayError
                .authoritativeGameRevisionMismatch
        }
        if requiresPlayerIdentity || observation.playerID != nil {
            guard observation.playerID == configuration.promptIdentity.ownerID else {
                throw ProductionAssignmentReplayError
                    .authoritativePlayerIdentityMismatch
            }
        }
        guard observation.projection == projection else {
            throw ProductionAssignmentReplayError.authoritativeProjectionMismatch
        }
    }
}

enum ProductionAssignmentReplayValidator {
    @MainActor
    // swiftlint:disable:next function_body_length
    static func validateStartingPrompt(
        _ prompt: BasicChoicePromptPresentation,
        projection: BoardProjection,
        configuration: ProductionAssignmentReplayConfiguration
    ) throws -> AssignmentReplayStartingObservation {
        guard prompt.identity.gameID == configuration.promptIdentity.gameID,
              prompt.ownerID == configuration.promptIdentity.ownerID,
              prompt.identity.sessionAttemptID != nil,
              prompt.identity.connectionID != nil
        else {
            throw ProductionAssignmentReplayError.startingPromptIdentityMismatch
        }
        guard prompt.questionVersion == configuration.expectedPromptVersion,
              projection.counters.scenarioSteps == configuration.expectedPromptVersion,
              projection.questions.count == 1,
              projection.questions[configuration.promptIdentity.ownerID]?.rawValue
              == prompt.identity.rawQuestion
        else {
            throw ProductionAssignmentReplayError.startingPromptVersionMismatch
        }
        let digest = try ProductionAssignmentReplayCanonicalJSON.promptDigest(
            prompt.identity.rawQuestion
        )
        guard digest == configuration.expectedPromptDigest else {
            throw ProductionAssignmentReplayError.startingPromptDigestMismatch
        }
        guard prompt.canSubmit,
              let question = prompt.question.supportedQuestion,
              question.kind == .questionWithSource,
              question.choices.map(\.index) == [0, 1],
              rawSourceIdentity(
                  prompt.identity.rawQuestion,
                  enemyID: configuration.promptIdentity.enemyID
              )
        else {
            throw ProductionAssignmentReplayError.startingPromptShapeMismatch
        }
        let expectedKinds: [EnemyAttackAssignmentKind] = [.damage, .horror]
        for (choice, expectedKind) in zip(question.choices, expectedKinds) {
            guard case let .assignEnemyAttackDamage(assignment) = choice.content,
                  assignment.kind == expectedKind,
                  assignment.enemyID == configuration.promptIdentity.enemyID,
                  assignment.investigatorID == configuration.promptIdentity.investigatorID,
                  prompt.isChoiceActionable(choice, in: projection)
            else {
                throw ProductionAssignmentReplayError.startingAssignmentMismatch
            }
        }
        let selected = question.choices[configuration.checkpoint.sourceIndex]
        guard case let .assignEnemyAttackDamage(assignment) = selected.content,
              assignment.kind == configuration.checkpoint.selectedAssignmentKind
        else {
            throw ProductionAssignmentReplayError.startingAssignmentMismatch
        }
        let assignmentBefore = try assignmentFields(
            projection,
            investigatorID: configuration.promptIdentity.investigatorID,
            missingError: .startingAssignmentFieldsMismatch
        )
        guard assignmentBefore == configuration.checkpoint.assignmentBefore else {
            throw ProductionAssignmentReplayError.startingAssignmentFieldsMismatch
        }
        return AssignmentReplayStartingObservation(
            assignmentBefore: assignmentBefore,
            promptDigest: digest
        )
    }

    @MainActor
    static func validateNextPrompt(
        _ prompt: BasicChoicePromptPresentation,
        projection: BoardProjection,
        configuration: ProductionAssignmentReplayConfiguration
    ) throws -> AssignmentReplayNextObservation {
        guard prompt.identity.gameID == configuration.promptIdentity.gameID,
              prompt.ownerID == configuration.promptIdentity.ownerID,
              prompt.identity.sessionAttemptID != nil,
              prompt.identity.connectionID != nil
        else {
            throw ProductionAssignmentReplayError.nextPromptIdentityMismatch
        }
        let expectedVersion = configuration.expectedPromptVersion + 1
        guard prompt.questionVersion == expectedVersion,
              projection.counters.scenarioSteps == expectedVersion,
              projection.questions.count == 1,
              projection.questions[configuration.promptIdentity.ownerID]?.rawValue
              == prompt.identity.rawQuestion
        else {
            throw ProductionAssignmentReplayError.nextPromptVersionMismatch
        }
        guard prompt.canSubmit,
              let question = prompt.question.supportedQuestion,
              question.kind == .questionWithSource,
              question.choices.map(\.index) == [0],
              rawSourceIdentity(
                  prompt.identity.rawQuestion,
                  enemyID: configuration.promptIdentity.enemyID
              )
        else {
            throw ProductionAssignmentReplayError.nextPromptShapeMismatch
        }
        let choice = question.choices[0]
        guard case let .assignEnemyAttackDamage(assignment) = choice.content,
              assignment.kind == configuration.checkpoint.nextAssignmentKind,
              assignment.enemyID == configuration.promptIdentity.enemyID,
              assignment.investigatorID == configuration.promptIdentity.investigatorID,
              prompt.isChoiceActionable(choice, in: projection)
        else {
            throw ProductionAssignmentReplayError.nextAssignmentMismatch
        }
        let assignmentAfter = try assignmentFields(
            projection,
            investigatorID: configuration.promptIdentity.investigatorID,
            missingError: .nextAssignmentFieldsMismatch
        )
        guard assignmentAfter == configuration.checkpoint.assignmentAfter else {
            throw ProductionAssignmentReplayError.nextAssignmentFieldsMismatch
        }
        return try AssignmentReplayNextObservation(
            assignmentAfter: assignmentAfter,
            promptDigest: ProductionAssignmentReplayCanonicalJSON.promptDigest(
                prompt.identity.rawQuestion
            )
        )
    }

    static func validateAssignmentDelta(
        before: AssignmentReplayFields,
        after: AssignmentReplayFields,
        checkpoint: ProductionAssignmentReplayCheckpoint
    ) throws -> AssignmentReplayFields {
        let delta = after.subtracting(before)
        guard delta == checkpoint.assignmentDelta else {
            throw ProductionAssignmentReplayError.assignmentDeltaMismatch
        }
        return delta
    }

    private static func rawSourceIdentity(
        _ rawQuestion: JSONValue,
        enemyID: EnemyID
    ) -> Bool {
        guard case let .object(root) = rawQuestion,
              root["tag"] == .string(BasicChoiceQuestionKind.questionWithSource.rawValue),
              case let .object(source)? = root["source"],
              Set(source.keys) == ["tag", "contents"],
              source["tag"] == .string("EnemyAttackSource"),
              source["contents"] == .string(enemyID.codingKey.stringValue)
        else {
            return false
        }
        return true
    }

    private static func assignmentFields(
        _ projection: BoardProjection,
        investigatorID: InvestigatorID,
        missingError: ProductionAssignmentReplayError
    ) throws -> AssignmentReplayFields {
        guard let investigator = projection.investigators.first(where: {
            $0.id == investigatorID
        }) else {
            throw missingError
        }
        return AssignmentReplayFields(
            assignedHealthDamage: investigator.assignedHealthDamage,
            assignedSanityDamage: investigator.assignedSanityDamage
        )
    }
}

@MainActor
// swiftlint:disable:next type_body_length
enum AssignmentContinuationReplayRunner {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func run(
        configuration: ProductionAssignmentReplayConfiguration
    ) async throws -> ProductionAssignmentReplayEvidence {
        let capabilityTransport = AssignmentReplayCapabilityTransport()
        let socketRecorder = ProductionAssignmentReplaySocketRecorder()
        let authoritativeRecorder =
            AssignmentReplayAuthoritativeRecorder()
        let gameTransport = AssignmentReplayRecordingGameTransport(
            recorder: authoritativeRecorder
        )
        let socketFactory = AssignmentReplayRecordingSocketFactory(
            recorder: socketRecorder,
            authoritativeRecorder: authoritativeRecorder
        )
        guard let assetCache = AssetCacheService.production() else {
            throw ProductionAssignmentReplayError.assetPipelineUnavailable
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
            authenticationSession: AuthenticationSession(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: GameLifecycleService(
                transport: gameTransport
            ),
            liveGameSocketFactory: socketFactory,
            localeCatalogLoader: .production(),
            preferredLanguagesProvider: SystemPreferredLanguages(),
            assetCacheService: assetCache,
            assetCacheFactory: { assetCache },
            storyAssetSourceLoader: StoryAssetSourceLoader()
        )
        defer {
            model.flowTask?.cancel()
            model.localeCatalogTask?.cancel()
        }

        await model.flowTask?.value
        let capabilities = try await validateBoot(
            model: model,
            capabilityTransport: capabilityTransport,
            configuration: configuration
        )
        if let catalogTask = model.localeCatalogTask {
            await catalogTask.value
        }
        try validateCatalogAndAssets(
            model: model,
            capabilities: capabilities,
            configuration: configuration
        )
        let attestationTransport =
            try AssignmentReplayBoundedHTTPTransport(
                maxByteCount:
                AssignmentReplayAttestationClient.maximumResponseBytes,
                timeout: configuration.deadlineSeconds
            )
        let attestation = try await AssignmentReplayAttestationClient(
            transport: attestationTransport
        ).fetch(request: configuration.attestationRequest)
        guard attestation == configuration.attestation else {
            throw ProductionAssignmentReplayError.serverAttestationMismatch
        }

        let subscription = model.subscribeToLiveGame(
            configuration.promptIdentity.gameID
        )
        defer { model.unsubscribeFromLiveGame(subscription) }
        let startingProjection = try await waitForStartingProjection(
            model: model,
            configuration: configuration
        )
        guard let startingAuthority = await authoritativeRecorder.latest(
            gameID: configuration.promptIdentity.gameID,
            questionVersion: configuration.expectedPromptVersion,
            source: .rest
        ) else {
            throw ProductionAssignmentReplayError
                .startingAuthoritativeObservationMissing
        }
        try AssignmentReplayAuthoritativeValidator.validate(
            startingAuthority,
            projection: startingProjection,
            configuration: configuration,
            attestation: attestation,
            requiresPlayerIdentity: true
        )
        guard model.liveGameParticipantIdentities[
            configuration.promptIdentity.gameID
        ] == .participant(configuration.promptIdentity.ownerID)
        else {
            throw ProductionAssignmentReplayError.sessionPlayerIdentityMismatch
        }
        let startingPrompt = try requirePrompt(
            model: model,
            gameID: configuration.promptIdentity.gameID,
            error: .startingPromptMissing
        )
        let starting = try ProductionAssignmentReplayValidator.validateStartingPrompt(
            startingPrompt,
            projection: startingProjection,
            configuration: configuration
        )

        var submittedSourceIndex: Int?
        var submissionTask: Task<BasicChoiceSubmitResult, Never>?
        let controller = BoardCommandController(
            projection: startingProjection,
            prompt: startingPrompt,
            onChoice: { sourceIndex in
                submittedSourceIndex = sourceIndex
                submissionTask = Task {
                    await model.submitBasicChoice(
                        startingPrompt.identity,
                        choiceIndex: sourceIndex
                    )
                }
            }
        )
        let jumpHandled = controller.handle(.command(.jumpToActivePrompt))
        guard jumpHandled else {
            throw ProductionAssignmentReplayError.controllerJumpRejected
        }
        let focusAfterJump = controller.coordinator.currentFocus
        guard focusAfterJump == BoardFocusID.promptChoice(0) else {
            throw ProductionAssignmentReplayError.controllerFocusMismatch
        }
        let movedToSelectedSourceIndex: Bool
        if configuration.checkpoint.sourceIndex == 0 {
            movedToSelectedSourceIndex = false
        } else {
            movedToSelectedSourceIndex = controller.handle(
                .command(.focusMove(.down))
            )
            guard movedToSelectedSourceIndex else {
                throw ProductionAssignmentReplayError.controllerMoveRejected
            }
        }
        let focusBeforePrimaryAction = controller.coordinator.currentFocus
        guard focusBeforePrimaryAction
            == BoardFocusID.promptChoice(configuration.checkpoint.sourceIndex)
        else {
            throw ProductionAssignmentReplayError.controllerFocusMismatch
        }
        let primaryActionHandled = controller.handle(.command(.primaryAction))
        guard primaryActionHandled else {
            throw ProductionAssignmentReplayError.controllerPrimaryActionRejected
        }
        guard submittedSourceIndex == configuration.checkpoint.sourceIndex else {
            throw ProductionAssignmentReplayError.controllerSourceIndexMismatch
        }
        guard let submissionTask else {
            throw ProductionAssignmentReplayError.controllerSubmissionMissing
        }
        let submissionResult = await submissionTask.value

        let expectedAnswer = BasicChoiceAnswer(
            choice: configuration.checkpoint.sourceIndex,
            playerID: configuration.promptIdentity.ownerID,
            questionVersion: configuration.expectedPromptVersion
        )
        let expectedAnswerData = try ContractJSON.encode(expectedAnswer)
        let sentAnswers = socketRecorder.snapshot()
        let sendProof =
            try AssignmentReplaySubmissionValidator.proveCanonicalSend(
                sentAnswers: sentAnswers,
                expectedData: expectedAnswerData,
                expectedAnswer: expectedAnswer
            )

        let nextProjection = try await waitForNextProjection(
            model: model,
            configuration: configuration
        )
        guard let nextAuthority = await authoritativeRecorder.latest(
            gameID: configuration.promptIdentity.gameID,
            questionVersion: configuration.expectedPromptVersion + 1
        ) else {
            throw ProductionAssignmentReplayError
                .nextAuthoritativeObservationMissing
        }
        try AssignmentReplayAuthoritativeValidator.validate(
            nextAuthority,
            projection: nextProjection,
            configuration: configuration,
            attestation: attestation,
            requiresPlayerIdentity: false
        )
        guard model.liveGameParticipantIdentities[
            configuration.promptIdentity.gameID
        ] == .participant(configuration.promptIdentity.ownerID)
        else {
            throw ProductionAssignmentReplayError.sessionPlayerIdentityMismatch
        }
        let nextPrompt = try requirePrompt(
            model: model,
            gameID: configuration.promptIdentity.gameID,
            error: .nextPromptMissing
        )
        let next = try ProductionAssignmentReplayValidator.validateNextPrompt(
            nextPrompt,
            projection: nextProjection,
            configuration: configuration
        )
        let assignmentDelta =
            try ProductionAssignmentReplayValidator.validateAssignmentDelta(
                before: starting.assignmentBefore,
                after: next.assignmentAfter,
                checkpoint: configuration.checkpoint
            )
        try AssignmentReplaySubmissionValidator.validateResolvedSubmission(
            submissionResult,
            sendProof: sendProof,
            nextProof: next
        )
        let evidence = ProductionAssignmentReplayEvidence(
            schemaVersion: ProductionAssignmentReplayEvidence
                .currentSchemaVersion,
            checkpoint: AssignmentReplayCheckpointEvidence(
                caseName: configuration.checkpoint.rawValue,
                validator: configuration.validatedCheckpoint.validator,
                validationStatus:
                configuration.validatedCheckpoint.validationStatus,
                playerID:
                configuration.validatedCheckpoint.checkpointPlayerID,
                questionVersion:
                configuration.validatedCheckpoint.questionVersion,
                promptCanonicalSHA256:
                configuration.validatedCheckpoint.promptSHA256,
                artifactSHA256:
                configuration.validatedCheckpoint.artifactSHA256,
                canonicalEnvelopeSHA256:
                configuration.validatedCheckpoint.canonicalEnvelopeSHA256,
                backendBuild: configuration.validatedCheckpoint.backendBuild,
                checkpointGameSHA256:
                configuration.validatedCheckpoint.checkpointGameSHA256,
                checkpointQueueSHA256:
                configuration.validatedCheckpoint.checkpointQueueSHA256
            ),
            source: ProductionAssignmentReplaySourceEvidence(
                gameID: configuration.promptIdentity.gameID,
                playerID: configuration.promptIdentity.ownerID,
                promptTag: BasicChoiceQuestionKind.questionWithSource.rawValue,
                sourceTag: "EnemyAttackSource",
                enemyID: configuration.promptIdentity.enemyID,
                investigatorID: configuration.promptIdentity.investigatorID,
                promptVersion: configuration.expectedPromptVersion,
                promptCanonicalSHA256: starting.promptDigest,
                selectedAssignment:
                configuration.checkpoint.selectedAssignmentKind.productionReplayName,
                sourceIndex: configuration.checkpoint.sourceIndex
            ),
            answer: expectedAnswer,
            controller: AssignmentReplayControllerEvidence(
                jumpToActivePromptHandled: jumpHandled,
                focusAfterJump: focusAfterJump?.rawValue ?? "",
                movedToSelectedSourceIndex: movedToSelectedSourceIndex,
                focusBeforePrimaryAction: focusBeforePrimaryAction?.rawValue ?? "",
                primaryActionHandled: primaryActionHandled
            ),
            assignmentBefore: starting.assignmentBefore,
            assignmentAfter: next.assignmentAfter,
            assignmentDelta: assignmentDelta,
            nextPrompt: AssignmentReplayNextPromptEvidence(
                promptTag: BasicChoiceQuestionKind.questionWithSource.rawValue,
                sourceTag: "EnemyAttackSource",
                assignment:
                configuration.checkpoint.nextAssignmentKind.productionReplayName,
                version: configuration.expectedPromptVersion + 1,
                canonicalSHA256: next.promptDigest
            ),
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
        return evidence
    }

    private static func validateBoot(
        model: AppModel,
        capabilityTransport: AssignmentReplayCapabilityTransport,
        configuration: ProductionAssignmentReplayConfiguration
    ) async throws -> ServerCapabilities {
        guard case let .signedIn(profile, compatibility, _) = model.sessionState,
              profile == configuration.serverProfile
        else {
            throw ProductionAssignmentReplayError.sessionNotSignedIn
        }
        let sessionCapabilities: Set<String>
        guard case let .modern(capabilities) = compatibility else {
            throw ProductionAssignmentReplayError.serverNotModern
        }
        sessionCapabilities = capabilities
        let serverCapabilities = try await capabilityTransport.decodedCapabilities()
        guard serverCapabilities.capabilities == sessionCapabilities,
              serverCapabilities.schemaRevision
              == configuration.expectedContractRevision,
              serverCapabilities.apiBasePath
              == ContractPin.current.expectedApiBasePath
        else {
            throw ProductionAssignmentReplayError.serverContractRevisionMismatch
        }
        guard serverCapabilities.localeCatalog?.catalogRevision
            == configuration.expectedCatalogRevision
        else {
            throw ProductionAssignmentReplayError.catalogAdvertisementMismatch
        }
        return serverCapabilities
    }

    private static func validateCatalogAndAssets(
        model: AppModel,
        capabilities: ServerCapabilities,
        configuration: ProductionAssignmentReplayConfiguration
    ) throws {
        guard let advertisement = capabilities.localeCatalog,
              advertisement.catalogRevision == configuration.expectedCatalogRevision,
              model.localeCatalogRequest == LocaleCatalogRequest(
                  profileID: configuration.serverProfile.id,
                  advertisement: advertisement
              ),
              model.localeCatalog?.identity.catalogRevision
              == configuration.expectedCatalogRevision
        else {
            throw ProductionAssignmentReplayError.catalogSnapshotMismatch
        }
        guard model.assetCacheService != nil,
              model.storyAssetSource != nil,
              model.storyAssetSourceFailure == nil
        else {
            throw ProductionAssignmentReplayError.storyAssetSourceUnavailable
        }
    }

    private static func waitForStartingProjection(
        model: AppModel,
        configuration: ProductionAssignmentReplayConfiguration
    ) async throws -> BoardProjection {
        let deadline = ContinuousClock.now + .seconds(configuration.deadlineSeconds)
        while ContinuousClock.now < deadline {
            switch model.liveGameState(for: configuration.promptIdentity.gameID) {
            case let .live(projection):
                return projection
            case .offline, .incompatiblePayload, .authenticationExpired, .terminalFailure:
                throw ProductionAssignmentReplayError.liveSessionFailed
            case .idle, .loading, .reconnecting:
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ProductionAssignmentReplayError.initialSnapshotTimedOut
    }

    private static func waitForNextProjection(
        model: AppModel,
        configuration: ProductionAssignmentReplayConfiguration
    ) async throws -> BoardProjection {
        let deadline = ContinuousClock.now + .seconds(configuration.deadlineSeconds)
        while ContinuousClock.now < deadline {
            switch model.liveGameState(for: configuration.promptIdentity.gameID) {
            case let .live(projection)
                where projection.counters.scenarioSteps
                != configuration.expectedPromptVersion:
                return projection
            case .offline, .incompatiblePayload, .authenticationExpired, .terminalFailure:
                throw ProductionAssignmentReplayError.liveSessionFailed
            case .idle, .loading, .live, .reconnecting:
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ProductionAssignmentReplayError.nextSnapshotTimedOut
    }

    private static func requirePrompt(
        model: AppModel,
        gameID: GameID,
        error: ProductionAssignmentReplayError
    ) throws -> BasicChoicePromptPresentation {
        guard let prompt = model.basicChoicePresentation(for: gameID) else {
            throw error
        }
        return prompt
    }
}
