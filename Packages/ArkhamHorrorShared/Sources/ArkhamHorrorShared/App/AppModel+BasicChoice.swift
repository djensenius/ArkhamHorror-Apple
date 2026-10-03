// swiftlint:disable file_length
import Foundation

private enum BasicChoiceSendPreparation {
    case send(connection: LiveGameConnectionHandle, actionAttemptID: UUID)
    case reject(BasicChoiceSubmitResult)
}

private enum BasicChoiceSubmissionEncodingError: Error {
    case invalidPresentation
}

extension AppModel {
    // swiftlint:disable:next function_body_length
    func basicChoicePresentation(for gameID: GameID) -> BasicChoicePromptPresentation? {
        guard let projection = liveGameStates[gameID]?.lastKnownProjection else { return nil }
        let identity = liveGameParticipantIdentities[gameID]
        let selected: (PlayerID, BasicChoiceQuestionPayload)? = switch identity {
        case let .participant(playerID):
            projection.questions[playerID].map { (playerID, $0) }
        case .spectator:
            firstQuestion(in: projection)
        case .none:
            nil
        }
        guard let (ownerID, payload) = selected else { return nil }

        let record = basicChoiceActions[gameID]
        let sessionAttemptID = liveGameSessions[gameID]?.attemptID
            ?? record?.identity.sessionAttemptID
        let connectionID = liveGameConnections[gameID]?.connectionID
            ?? (
                record?.identity.sessionAttemptID == sessionAttemptID
                    ? record?.identity.connectionID : nil
            )
        let promptKey = basicChoicePromptKey(
            gameID: gameID, ownerID: ownerID, payload: payload, projection: projection
        )
        let promptIdentity = basicChoicePromptIdentity(
            promptKey,
            sessionAttemptID: sessionAttemptID,
            connectionID: connectionID
        )
        let readOnlyReason = readOnlyReason(
            gameID: gameID, ownerID: ownerID, payload: payload
        )
        let isSamePrompt = record?.identity.promptKey == promptIdentity.promptKey
        let isCurrentTransport = record?.identity == promptIdentity
        let phase: BasicChoiceActionPhase? = if isSamePrompt {
            if isCurrentTransport {
                record?.phase
            } else {
                .uncertain
            }
        } else {
            nil
        }
        let supportedQuestion = payload.state.supportedQuestion
        let storyResolution = storyResolution(for: supportedQuestion?.story)
            ?? storyResolution(for: payload.presentation?.presentation.flavorText)
        let labelResolutions = choiceLabelResolutions(
            for: supportedQuestion,
            semanticPresentation: payload.presentation
        )
        let choiceFlavorResolutions = choiceFlavorResolutions(for: payload.presentation)
        let promptLabelResolutions = promptLabelResolutions(
            for: payload.presentation?.presentation
        )
        let localizationReasons = [storyResolution?.unavailableReason].compactMap(\.self)
            + labelResolutions.values.compactMap(\.unavailableReason)
            + choiceFlavorResolutions.values.compactMap(\.unavailableReason)
            + promptLabelResolutions.values.compactMap(\.unavailableReason)
        return BasicChoicePromptPresentation(
            identity: promptIdentity,
            question: payload.state,
            semanticPresentation: payload.presentation,
            semanticLocaleIdentifier: localeCatalogResolver?.snapshot.identity.locale,
            cardCatalog: cardCatalog,
            storyResolution: storyResolution,
            choiceLabelResolutions: labelResolutions,
            choiceFlavorResolutions: choiceFlavorResolutions,
            promptLabelResolutions: promptLabelResolutions,
            readOnlyReason: readOnlyReason,
            actionPhase: phase,
            actionChoiceIndex: isSamePrompt ? record?.choiceIndex : nil,
            serverFeedback: basicChoiceServerFeedback[gameID],
            catalogRetry: catalogRetryPresentation(
                localizationReasons: localizationReasons,
                promptKey: promptIdentity.promptKey
            )
        )
    }

    func basicChoicePromptKey(
        gameID: GameID,
        ownerID: PlayerID,
        payload: BasicChoiceQuestionPayload,
        projection: BoardProjection
    ) -> BasicChoicePromptKey {
        BasicChoicePromptKey(
            gameID: gameID,
            ownerID: ownerID,
            questionVersion: projection.counters.scenarioSteps,
            rawQuestion: payload.rawValue,
            questionPresentation: payload.presentation?.presentation
        )
    }

    private func basicChoicePromptIdentity(
        _ key: BasicChoicePromptKey,
        sessionAttemptID: UUID?,
        connectionID: UUID?
    ) -> BasicChoicePromptIdentity {
        BasicChoicePromptIdentity(
            gameID: key.gameID,
            ownerID: key.ownerID,
            questionVersion: key.questionVersion,
            rawQuestion: key.rawQuestion,
            questionPresentation: key.questionPresentation,
            sessionAttemptID: sessionAttemptID,
            connectionID: connectionID
        )
    }

    private func firstQuestion(
        in projection: BoardProjection
    ) -> (PlayerID, BasicChoiceQuestionPayload)? {
        projection.questions
            .min { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }
            .map { ($0.key, $0.value) }
    }

    private func readOnlyReason(
        gameID: GameID, ownerID: PlayerID, payload: BasicChoiceQuestionPayload
    ) -> BasicChoiceReadOnlyReason? {
        let hasRenderableQuestion = if let semanticPresentation = payload.presentation {
            semanticPresentation.isRenderableInCurrentClient
                && BasicChoicePromptPresentation.supportsSemanticPrompt(
                    rawQuestion: payload.rawValue,
                    presentation: semanticPresentation.presentation
                )
        } else {
            payload.supportedQuestion?.choices.isEmpty == false
        }
        guard let identity = liveGameParticipantIdentities[gameID] else { return .disconnected }
        switch identity {
        case .spectator:
            return .spectator
        case let .participant(playerID) where playerID != ownerID:
            return .anotherPlayer
        case .participant:
            break
        }
        guard case let .signedIn(_, compatibility, _) = sessionState,
              case .modern = compatibility
        else { return .legacyServer }
        guard liveGameConnections[gameID] != nil else { return .disconnected }
        guard hasRenderableQuestion else { return .updateRequired }
        return nil
    }

    func submitBasicChoice(
        _ identity: BasicChoicePromptIdentity, choiceIndex: Int
    ) async -> BasicChoiceSubmitResult {
        await sendBasicChoice(identity, submission: .singleChoice(choiceIndex), isRetry: false)
    }

    func submitAmountsAnswer(
        _ identity: BasicChoicePromptIdentity, amounts: [String: Int]
    ) async -> BasicChoiceSubmitResult {
        await sendBasicChoice(identity, submission: .amounts(amounts), isRetry: false)
    }

    func submitPaymentAmountsAnswer(
        _ identity: BasicChoicePromptIdentity, amounts: [String: Int]
    ) async -> BasicChoiceSubmitResult {
        await sendBasicChoice(identity, submission: .paymentAmounts(amounts), isRetry: false)
    }

    func submitExchangeAmountsAnswer(
        _ identity: BasicChoicePromptIdentity, amount: Int
    ) async -> BasicChoiceSubmitResult {
        await sendBasicChoice(identity, submission: .exchangeAmount(amount), isRetry: false)
    }

    func submitContinueCampaignAnswer(
        _ identity: BasicChoicePromptIdentity, step: JSONValue
    ) async -> BasicChoiceSubmitResult {
        await sendBasicChoice(identity, submission: .continueCampaign(step), isRetry: false)
    }

    func retryBasicChoice(_ identity: BasicChoicePromptIdentity) async -> BasicChoiceSubmitResult {
        guard let record = basicChoiceActions[identity.gameID],
              record.identity == identity,
              case .retryable = record.phase
        else { return .staleQuestion }
        return await sendBasicChoice(identity, submission: record.submission, isRetry: true)
    }

    private func sendBasicChoice(
        _ identity: BasicChoicePromptIdentity, submission: BasicChoiceSubmission, isRetry: Bool
    ) async -> BasicChoiceSubmitResult {
        let preparation = prepareBasicChoiceSend(
            identity, submission: submission, isRetry: isRetry
        )
        guard case let .send(connection, actionAttemptID) = preparation else {
            guard case let .reject(result) = preparation else { return .retryableFailure }
            return result
        }
        return await performBasicChoiceSend(
            identity,
            submission: submission,
            connection: connection,
            actionAttemptID: actionAttemptID
        )
    }

    private func prepareBasicChoiceSend(
        _ identity: BasicChoicePromptIdentity, submission: BasicChoiceSubmission, isRetry: Bool
    ) -> BasicChoiceSendPreparation {
        guard let presentation = basicChoicePresentation(for: identity.gameID),
              presentation.identity == identity
        else { return .reject(.staleQuestion) }
        if let action = basicChoiceActions[identity.gameID] {
            if action.identity.promptKey != identity.promptKey {
                basicChoiceActions[identity.gameID] = nil
            } else {
                switch action.phase {
                case .sending, .awaitingSnapshot, .uncertain:
                    return .reject(.alreadyPending)
                case .retryable where !isRetry:
                    return .reject(.alreadyPending)
                case .retryable:
                    break
                }
            }
        }
        guard presentation.isAuthorized else {
            return .reject(.readOnly)
        }
        // Revalidated immediately before send using the current authoritative prompt
        // identity and actionability rules -- never the projection captured whenever
        // this choice was last rendered. Generic semantic choices trust the
        // server-owned descriptor except for client display prerequisites such as
        // resolvable label text.
        guard let projection = liveGameStates[identity.gameID]?.lastKnownProjection,
              presentation.isSubmissionSupported(submission, in: projection)
        else { return .reject(.unsupportedChoice) }
        guard isRetry || presentation.canSubmit else {
            return .reject(.readOnly)
        }
        guard let connection = liveGameConnections[identity.gameID],
              liveGameSessions[identity.gameID]?.attemptID == connection.attemptID
        else { return .reject(.readOnly) }

        let actionAttemptID = UUID()
        basicChoiceActions[identity.gameID] = BasicChoiceActionRecord(
            identity: identity,
            submission: submission,
            attemptID: actionAttemptID,
            connectionID: connection.connectionID,
            phase: .sending
        )
        return .send(connection: connection, actionAttemptID: actionAttemptID)
    }

    private func performBasicChoiceSend(
        _ identity: BasicChoicePromptIdentity,
        submission: BasicChoiceSubmission,
        connection: LiveGameConnectionHandle,
        actionAttemptID: UUID
    ) async -> BasicChoiceSubmitResult {
        let bytes: Data
        do {
            bytes = try encodeSubmission(submission, identity: identity)
        } catch {
            updateBasicChoiceAction(
                gameID: identity.gameID,
                actionAttemptID: actionAttemptID,
                phase: .retryable(.transportFailure)
            )
            return .retryableFailure
        }

        do {
            try await connection.connection.send(bytes)
            try Task.checkCancellation()
        } catch is CancellationError {
            updateBasicChoiceAction(
                gameID: identity.gameID,
                actionAttemptID: actionAttemptID,
                phase: .uncertain
            )
            return .retryableFailure
        } catch {
            updateBasicChoiceAction(
                gameID: identity.gameID,
                actionAttemptID: actionAttemptID,
                phase: .retryable(.transportFailure)
            )
            return .retryableFailure
        }

        guard liveGameSessions[identity.gameID]?.attemptID == connection.attemptID,
              liveGameConnections[identity.gameID]?.connectionID == connection.connectionID,
              basicChoiceActions[identity.gameID]?.attemptID == actionAttemptID,
              basicChoiceActions[identity.gameID]?.phase == .sending
        else {
            return .retryableFailure
        }
        basicChoiceActions[identity.gameID]?.phase = .awaitingSnapshot
        return .sentAwaitingSnapshot
    }

    private func encodeSubmission(
        _ submission: BasicChoiceSubmission,
        identity: BasicChoicePromptIdentity
    ) throws -> Data {
        switch submission {
        case let .singleChoice(choiceIndex):
            return try ContractJSON.encode(BasicChoiceAnswer(
                choice: choiceIndex,
                playerID: identity.ownerID,
                questionVersion: identity.questionVersion
            ))
        case let .amounts(amounts):
            return try ContractJSON.encode(AmountsAnswer(
                amounts: amounts,
                playerID: identity.ownerID,
                questionVersion: identity.questionVersion
            ))
        case let .paymentAmounts(amounts):
            return try ContractJSON.encode(PaymentAmountsAnswer(
                amounts: amounts,
                playerID: identity.ownerID,
                questionVersion: identity.questionVersion
            ))
        case let .exchangeAmount(amount):
            guard let source = identity.questionPresentation?.source?.raw,
                  let fromInvestigator = identity.questionPresentation?.fromInvestigator,
                  let toInvestigator = identity.questionPresentation?.toInvestigator,
                  let token = identity.questionPresentation?.token
            else { throw BasicChoiceSubmissionEncodingError.invalidPresentation }
            return try ContractJSON.encode(ExchangeAmountsAnswer(
                source: source,
                fromInvestigator: fromInvestigator,
                toInvestigator: toInvestigator,
                token: token,
                amount: amount
            ))
        case let .continueCampaign(step):
            return try ContractJSON.encode(CampaignStepAnswer(contents: step))
        }
    }

    private func updateBasicChoiceAction(
        gameID: GameID, actionAttemptID: UUID, phase: BasicChoiceActionPhase
    ) {
        guard basicChoiceActions[gameID]?.attemptID == actionAttemptID,
              basicChoiceActions[gameID]?.phase == .sending
        else { return }
        basicChoiceActions[gameID]?.phase = phase
    }

    func markBasicChoiceOutcomeUncertain(
        gameID: GameID, connectionID: UUID? = nil
    ) {
        guard let action = basicChoiceActions[gameID] else { return }
        if let connectionID, action.connectionID != connectionID {
            return
        }
        switch action.phase {
        case .sending, .awaitingSnapshot:
            basicChoiceActions[gameID]?.phase = .uncertain
        case .uncertain, .retryable:
            break
        }
    }

    func reconcileBasicChoice(
        gameID: GameID, projection: BoardProjection, isRESTSnapshot: Bool
    ) {
        reconcileCampaignDeckSubmission(gameID: gameID, projection: projection)
        guard let action = basicChoiceActions[gameID] else { return }
        guard case let .participant(playerID) = liveGameParticipantIdentities[gameID],
              playerID == action.identity.ownerID
        else {
            basicChoiceActions[gameID] = nil
            return
        }
        let current = projection.questions[action.identity.ownerID]
        let samePrompt = projection.counters.scenarioSteps == action.identity.questionVersion
            && current?.rawValue == action.identity.rawQuestion
            && current?.presentation?.presentation == action.identity.questionPresentation
        guard samePrompt else {
            basicChoiceActions[gameID] = nil
            return
        }
        if isRESTSnapshot {
            basicChoiceActions[gameID]?.identity = BasicChoicePromptIdentity(
                gameID: gameID,
                ownerID: action.identity.ownerID,
                questionVersion: action.identity.questionVersion,
                rawQuestion: action.identity.rawQuestion,
                questionPresentation: action.identity.questionPresentation,
                sessionAttemptID: liveGameSessions[gameID]?.attemptID,
                connectionID: liveGameConnections[gameID]?.connectionID
            )
            if let connectionID = liveGameConnections[gameID]?.connectionID {
                basicChoiceActions[gameID]?.connectionID = connectionID
            }
            if action.phase == .uncertain {
                basicChoiceActions[gameID]?.phase = .retryable(.outcomeUncertain)
            }
        }
        retireStaleRetryRecordIfNeeded(gameID: gameID, current: current, projection: projection)
    }

    /// A `.retryable` record is definitively not in flight -- the exact same authoritative
    /// prompt (`samePrompt`, established by the caller: same `scenarioSteps` *and* same raw
    /// question bytes) has just been observed again unanswered, so the prior send attempt
    /// provably never advanced the game. That lets us safely retire records that no longer
    /// point at an activatable answer: missing original choices/descriptors, semantic
    /// choices rejected by the server-provided presentation or label resolution, or legacy
    /// choices that the current projection cannot submit. Retiring those stale records lets
    /// a different, currently-actionable choice proceed instead of being permanently blocked
    /// behind them (see independent-review blocker 2 on PR #36).
    ///
    /// Deliberately never applied to `.sending`/`.awaitingSnapshot`/`.uncertain`: while a
    /// send might still be in flight or its outcome is still genuinely unknown, retiring
    /// the record here could let a second, different choice be claimed and sent while the
    /// first is still capable of landing, producing two accepted answers for one prompt.
    /// If the original choice remains actionable, the record is left untouched entirely,
    /// preserving the existing manual-retry path.
    private func retireStaleRetryRecordIfNeeded(
        gameID: GameID, current: BasicChoiceQuestionPayload?, projection: BoardProjection
    ) {
        guard case .retryable = basicChoiceActions[gameID]?.phase,
              let choiceIndex = basicChoiceActions[gameID]?.choiceIndex,
              let current,
              let ownerID = basicChoiceActions[gameID]?.identity.ownerID
        else { return }
        let question = current.supportedQuestion
        let choices = BasicChoicePromptPresentation.makeChoices(
            question: current.state,
            semanticPresentation: current.presentation
        )
        guard let originalChoice = choices.first(where: { $0.index == choiceIndex }) else {
            basicChoiceActions[gameID] = nil
            return
        }
        let labelResolutions = choiceLabelResolutions(
            for: question,
            semanticPresentation: current.presentation
        )
        let isActionable: Bool
        if let semanticPresentation = current.presentation {
            guard let descriptor = semanticPresentation.descriptor(
                forSourceIndex: originalChoice.index
            ) else {
                basicChoiceActions[gameID] = nil
                return
            }
            isActionable = semanticPresentation.canActivateSemanticChoice(
                descriptor,
                labelResolution: labelResolutions[choiceIndex]
            )
        } else {
            isActionable = projection.isChoiceActionable(
                originalChoice,
                ownerID: ownerID,
                storyResolution: storyResolution(for: question?.story),
                labelResolution: labelResolutions[choiceIndex]
            )
        }
        guard !isActionable else { return }
        basicChoiceActions[gameID] = nil
    }

    /// `GameError` is broadcast room-wide and carries no player, question, or request
    /// correlation. It therefore cannot prove this client's answer was rejected.
    /// Definitive rejection requires a future backend correlation field.
    func handleUncorrelatedBasicChoiceGameError(
        gameID: GameID, sessionAttemptID: UUID, connectionID: UUID?
    ) {
        basicChoiceServerFeedback[gameID] =
            "The server reported a game error that could not be tied to your choice."
        guard let action = basicChoiceActions[gameID],
              action.identity.sessionAttemptID == sessionAttemptID,
              action.connectionID == connectionID
        else { return }
        switch action.phase {
        case .sending, .awaitingSnapshot:
            basicChoiceActions[gameID]?.phase = .retryable(.outcomeUncertain)
        case .uncertain, .retryable:
            break
        }
    }
}

private extension BasicChoicePromptPresentation {
    func isSubmissionSupported(
        _ submission: BasicChoiceSubmission,
        in projection: BoardProjection
    ) -> Bool {
        switch submission {
        case let .singleChoice(choiceIndex):
            guard let choice = choices.first(where: { $0.index == choiceIndex }) else {
                return false
            }
            return canSubmitSingleChoiceAnswer && isChoiceActionable(choice, in: projection)
        case let .amounts(amounts):
            return supportsAmountSubmission(amounts)
        case let .paymentAmounts(amounts):
            return supportsPaymentAmountSubmission(amounts)
        case let .exchangeAmount(amount):
            return supportsExchangeSubmission(amount)
        case let .continueCampaign(step):
            return supportsContinueCampaignSubmission(step, in: projection)
        }
    }

    func supportsAmountSubmission(_ amounts: [String: Int]) -> Bool {
        guard let presentation = semanticPresentation?.presentation,
              case .amounts = presentation.answer,
              Self.supportsSemanticPrompt(
                  rawQuestion: identity.rawQuestion,
                  presentation: presentation
              ),
              let choices = presentation.amountChoices,
              amountRowLabelsResolved(
                  choices.map {
                      AmountRowLabel(
                          key: amountChoicePromptLabelKey($0.choiceID),
                          text: $0.label,
                          upperBound: $0.maxBound
                      )
                  }
              )
        else { return false }
        return amountAllocationValid(
            amounts: amounts,
            choices: choices.map {
                AmountChoiceBounds(
                    id: $0.choiceID,
                    lowerBound: $0.minBound,
                    upperBound: $0.maxBound
                )
            },
            target: presentation.target
        )
    }

    func supportsPaymentAmountSubmission(_ amounts: [String: Int]) -> Bool {
        guard let presentation = semanticPresentation?.presentation,
              case .paymentAmounts = presentation.answer,
              Self.supportsSemanticPrompt(
                  rawQuestion: identity.rawQuestion,
                  presentation: presentation
              ),
              let choices = presentation.paymentChoices,
              amountRowLabelsResolved(
                  choices.map {
                      AmountRowLabel(
                          key: paymentChoicePromptLabelKey($0.choiceID),
                          text: $0.title.text,
                          upperBound: $0.max
                      )
                  }
              )
        else { return false }
        return amountAllocationValid(
            amounts: amounts,
            choices: choices.map {
                AmountChoiceBounds(id: $0.choiceID, lowerBound: $0.min, upperBound: $0.max)
            },
            target: presentation.target
        )
    }

    func supportsExchangeSubmission(_ amount: Int) -> Bool {
        guard let presentation = semanticPresentation?.presentation,
              case .exchangeAmounts = presentation.answer,
              Self.supportsSemanticPrompt(
                  rawQuestion: identity.rawQuestion,
                  presentation: presentation
              ),
              let fromInitialAmount = presentation.fromInitialAmount,
              let toInitialAmount = presentation.toInitialAmount,
              presentation.source != nil,
              presentation.fromInvestigator != nil,
              presentation.toInvestigator != nil,
              presentation.token != nil
        else { return false }
        guard fromInitialAmount >= 0, toInitialAmount >= 0 else { return false }
        let lowerBound = 0.subtractingReportingOverflow(toInitialAmount)
        guard !lowerBound.overflow, lowerBound.partialValue <= fromInitialAmount else {
            return false
        }
        return amount >= lowerBound.partialValue && amount <= fromInitialAmount
    }

    func supportsContinueCampaignSubmission(
        _ step: JSONValue,
        in projection: BoardProjection
    ) -> Bool {
        guard let presentation = semanticPresentation?.presentation,
              case .continueCampaign = presentation.answer,
              Self.supportsSemanticPrompt(
                  rawQuestion: identity.rawQuestion,
                  presentation: presentation
              ),
              let continuation = projection.campaignContinuation
        else { return false }
        return step == continuation.nextStep
            || (continuation.canUpgradeDecks && step == continuation.upgradeStep)
    }

    struct AmountChoiceBounds: Sendable, Equatable {
        let id: String
        let lowerBound: Int
        let upperBound: Int
    }

    struct AmountRowLabel: Sendable, Equatable {
        let key: String
        let text: String
        let upperBound: Int
    }

    func amountRowLabelsResolved(_ labels: [AmountRowLabel]) -> Bool {
        labels.allSatisfy { label in
            amountRowLabelUnavailableReason(
                key: label.key,
                labelText: label.text,
                upperBound: label.upperBound
            ) == nil
        }
    }

    func amountAllocationValid(
        amounts: [String: Int],
        choices: [AmountChoiceBounds],
        target: QuestionPresentation.AmountTarget?
    ) -> Bool {
        let choiceIDs = Set(choices.map(\.id))
        guard choiceIDs.count == choices.count,
              Set(amounts.keys) == choiceIDs
        else { return false }
        var total = 0
        for choice in choices {
            guard choice.lowerBound <= choice.upperBound,
                  let amount = amounts[choice.id],
                  amount >= choice.lowerBound,
                  amount <= choice.upperBound
            else { return false }
            let result = total.addingReportingOverflow(amount)
            guard !result.overflow else { return false }
            total = result.partialValue
        }
        return amountTargetSatisfied(target, total: total)
    }

    func amountTargetSatisfied(
        _ target: QuestionPresentation.AmountTarget?, total: Int
    ) -> Bool {
        switch target {
        case nil:
            true
        case let .min(minimum):
            total >= minimum
        case let .max(maximum):
            total <= maximum
        case let .total(required):
            total == required
        case let .oneOf(allowed):
            allowed.contains(total)
        }
    }
}

// swiftlint:enable file_length
