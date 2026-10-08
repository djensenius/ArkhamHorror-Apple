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
        case .spectator, .none:
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
        let pickDestinyPrompt = pickDestinyPromptPresentation(
            for: payload.presentation?.presentation,
            campaignScope: projection.campaignI18nScope
        )
        let localizationReasons = [storyResolution?.unavailableReason].compactMap(\.self)
            + labelResolutions.values.compactMap(\.unavailableReason)
            + choiceFlavorResolutions.values.compactMap(\.unavailableReason)
            + promptLabelResolutions.values.compactMap(\.unavailableReason)
            + [pickDestinyPrompt?.unavailableReason].compactMap(\.self)
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
            pickDestinyPrompt: pickDestinyPrompt,
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

    func submitPickDestinyAnswer(
        _ identity: BasicChoicePromptIdentity,
        drawings: [QuestionPresentation.DestinyDrawing]
    ) async -> BasicChoiceSubmitResult {
        await sendBasicChoice(identity, submission: .pickDestiny(drawings), isRetry: false)
    }

    func submitCampaignSpecificAnswer(
        _ identity: BasicChoicePromptIdentity,
        contents: JSONValue
    ) async -> BasicChoiceSubmitResult {
        await sendBasicChoice(identity, submission: .campaignSpecific(contents), isRetry: false)
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
        guard clientActionabilityAllows(
            submission,
            presentation: presentation,
            gameID: identity.gameID
        ) else { return .reject(.unsupportedChoice) }
        guard isRetry || presentation.canSubmit else {
            return .reject(.readOnly)
        }
        guard let connection = liveGameConnections[identity.gameID],
              liveGameSessions[identity.gameID]?.attemptID == connection.attemptID
        else { return .reject(.readOnly) }

        clearBasicChoiceServerFeedback(gameID: identity.gameID)
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

    private func clientActionabilityAllows(
        _ submission: BasicChoiceSubmission,
        presentation: BasicChoicePromptPresentation,
        gameID: GameID
    ) -> Bool {
        guard submission.needsClientActionabilityCheck else { return true }
        guard let projection = liveGameStates[gameID]?.lastKnownProjection else { return false }
        return presentation.isSubmissionSupported(submission, in: projection)
    }

    // swiftlint:disable:next function_body_length
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
            if consumeBasicChoiceRejectedAttempt(
                gameID: identity.gameID,
                actionAttemptID: actionAttemptID
            ) {
                return .sentAwaitingSnapshot
            }
            updateBasicChoiceAction(
                gameID: identity.gameID,
                actionAttemptID: actionAttemptID,
                phase: .uncertain
            )
            return .retryableFailure
        } catch {
            if consumeBasicChoiceRejectedAttempt(
                gameID: identity.gameID,
                actionAttemptID: actionAttemptID
            ) {
                return .sentAwaitingSnapshot
            }
            updateBasicChoiceAction(
                gameID: identity.gameID,
                actionAttemptID: actionAttemptID,
                phase: .retryable(.transportFailure)
            )
            return .retryableFailure
        }

        if consumeBasicChoiceRejectedAttempt(
            gameID: identity.gameID,
            actionAttemptID: actionAttemptID
        ) {
            return .sentAwaitingSnapshot
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

    func consumeBasicChoiceRejectedAttempt(
        gameID: GameID,
        actionAttemptID: UUID
    ) -> Bool {
        guard basicChoiceRejectedAttemptIDs[gameID]?.contains(actionAttemptID) == true else {
            return false
        }
        basicChoiceRejectedAttemptIDs[gameID]?.remove(actionAttemptID)
        if basicChoiceRejectedAttemptIDs[gameID]?.isEmpty == true {
            basicChoiceRejectedAttemptIDs[gameID] = nil
        }
        return true
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
        case let .pickDestiny(drawings):
            return try ContractJSON.encode(PickDestinyAnswer(contents: drawings))
        case let .campaignSpecific(contents):
            return try ContractJSON.encode(CampaignSpecificAnswer(contents: contents))
        case let .deck(deckID):
            return try ContractJSON.encode(DeckAnswer(
                deckId: deckID,
                playerId: identity.ownerID
            ))
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
        guard case .retryable = basicChoiceActions[gameID]?.phase else { return }
        if case .deck = basicChoiceActions[gameID]?.submission {
            return
        }
        guard let choiceIndex = basicChoiceActions[gameID]?.choiceIndex,
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

    func handleBasicChoiceAnswerRejected(
        gameID: GameID,
        sessionAttemptID: UUID,
        connectionID: UUID?,
        rejection: AnswerRejectedMessage
    ) {
        guard let action = basicChoiceActions[gameID],
              action.identity.gameID == gameID,
              action.identity.sessionAttemptID == sessionAttemptID,
              liveGameParticipantIdentities[gameID] == .participant(action.identity.ownerID)
        else { return }
        if let connectionID, action.connectionID != connectionID {
            return
        }
        if let questionVersion = rejection.questionVersion {
            guard questionVersion == action.identity.questionVersion else { return }
        } else {
            guard action.submission.acceptsUnversionedRejection else { return }
        }
        setBasicChoiceServerFeedback(
            gameID: gameID,
            message: rejection.reason,
            source: .answerRejected
        )
        if action.phase == .sending {
            basicChoiceRejectedAttemptIDs[gameID, default: []].insert(action.attemptID)
        }
        basicChoiceActions[gameID] = nil
    }

    func clearBasicChoiceServerFeedback(gameID: GameID) {
        basicChoiceServerFeedback[gameID] = nil
        basicChoiceServerFeedbackSources[gameID] = nil
    }

    func setBasicChoiceServerFeedback(
        gameID: GameID,
        message: String,
        source: BasicChoiceServerFeedbackSource
    ) {
        basicChoiceServerFeedback[gameID] = message
        basicChoiceServerFeedbackSources[gameID] = source
    }

    /// `GameError` is broadcast room-wide and carries no player, question, or request
    /// correlation. It is generic feedback, not an answer rejection; a same-transport
    /// in-flight choice can only become outcome-uncertain until an authoritative
    /// `AnswerRejected` or changed snapshot arrives.
    func handleUncorrelatedBasicChoiceGameError(
        gameID: GameID, sessionAttemptID: UUID, connectionID: UUID?
    ) {
        setBasicChoiceServerFeedback(
            gameID: gameID,
            message: "The server reported a game error that could not be tied to your choice.",
            source: .gameError
        )
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

private extension BasicChoiceSubmission {
    var needsClientActionabilityCheck: Bool {
        switch self {
        case .singleChoice, .amounts, .paymentAmounts, .exchangeAmount, .continueCampaign,
             .pickDestiny, .campaignSpecific:
            true
        case .deck:
            false
        }
    }

    var acceptsUnversionedRejection: Bool {
        switch self {
        case .exchangeAmount, .continueCampaign, .pickDestiny, .campaignSpecific, .deck:
            true
        case .singleChoice, .amounts, .paymentAmounts:
            false
        }
    }
}

extension BasicChoicePromptPresentation {
    // swiftlint:disable:next cyclomatic_complexity
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
        case .amounts:
            guard let amountPrompt = amountPrompt(in: projection),
                  amountPrompt.kind == .amounts
            else { return false }
            return !hasUnresolvedAmountRowLabels
        case .paymentAmounts:
            guard let amountPrompt = amountPrompt(in: projection),
                  amountPrompt.kind == .payment
            else { return false }
            return !hasUnresolvedAmountRowLabels
        case .exchangeAmount:
            return exchangePrompt(in: projection) != nil
        case let .continueCampaign(step):
            return supportsContinueCampaignSubmission(step, in: projection)
        case let .pickDestiny(drawings):
            return supportsPickDestinySubmission(drawings)
        case let .campaignSpecific(contents):
            return supportsCampaignSpecificSubmission(contents)
        case .deck:
            return true
        }
    }

    func supportsPickDestinySubmission(
        _ drawings: [QuestionPresentation.DestinyDrawing]
    ) -> Bool {
        guard let presentation = semanticPresentation?.presentation,
              presentation.questionKind == .pickDestiny,
              case .pickDestiny = presentation.answer,
              Self.supportsSemanticPrompt(
                  rawQuestion: identity.rawQuestion,
                  presentation: presentation
              ),
              let publishedDrawings = presentation.drawings,
              !publishedDrawings.isEmpty,
              let rawDrawings = PickDestinySelectionRules.publishedDrawings(
                  in: identity.rawQuestion
              ),
              !rawDrawings.isEmpty,
              PickDestinySelectionRules.matchesPublishedSequence(
                  publishedDrawings,
                  published: rawDrawings
              )
        else { return false }
        return PickDestinySelectionRules.canSubmit(drawings, published: rawDrawings)
    }

    func supportsCampaignSpecificSubmission(_ contents: JSONValue) -> Bool {
        guard let presentation = semanticPresentation?.presentation,
              case .campaignSpecific = presentation.answer,
              Self.supportsSemanticPrompt(
                  rawQuestion: identity.rawQuestion,
                  presentation: presentation
              )
        else { return false }
        return ScarletKeysTravelPromptPresentation.supportsSubmission(
            contents,
            rawQuestion: identity.rawQuestion,
            presentation: presentation,
            labelResolutions: promptLabelResolutions
        )
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
}

// swiftlint:enable file_length
