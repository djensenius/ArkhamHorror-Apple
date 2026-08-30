import Foundation

private enum BasicChoiceSendPreparation {
    case send(connection: LiveGameConnectionHandle, actionAttemptID: UUID)
    case reject(BasicChoiceSubmitResult)
}

extension AppModel {
    func basicChoicePresentation(for gameID: GameID) -> BasicChoicePromptPresentation? {
        guard let projection = liveGameStates[gameID]?.lastKnownProjection else { return nil }
        let identity = liveGameParticipantIdentities[gameID]
        let selected: (PlayerID, BasicChoiceQuestionPayload)? = switch identity {
        case let .participant(playerID):
            if let ownQuestion = projection.questions[playerID] {
                (playerID, ownQuestion)
            } else {
                firstQuestion(in: projection)
            }
        case .spectator, .none:
            firstQuestion(in: projection)
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
        let promptIdentity = BasicChoicePromptIdentity(
            gameID: gameID,
            ownerID: ownerID,
            questionVersion: projection.counters.scenarioSteps,
            rawQuestion: payload.rawValue,
            sessionAttemptID: sessionAttemptID,
            connectionID: connectionID
        )
        let readOnlyReason = readOnlyReason(
            gameID: gameID, ownerID: ownerID, question: payload.state
        )
        let phase: BasicChoiceActionPhase? = if record?.identity == promptIdentity {
            record?.phase
        } else if record?.phase == .accepted {
            .accepted
        } else {
            nil
        }
        return BasicChoicePromptPresentation(
            identity: promptIdentity,
            question: payload.state,
            readOnlyReason: readOnlyReason,
            actionPhase: phase,
            actionChoiceIndex: record?.identity == promptIdentity ? record?.choiceIndex : nil
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
        gameID: GameID, ownerID: PlayerID, question: BasicChoiceQuestionState
    ) -> BasicChoiceReadOnlyReason? {
        guard question.supportedQuestion != nil else { return .updateRequired }
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
        return nil
    }

    func submitBasicChoice(
        _ identity: BasicChoicePromptIdentity, choiceIndex: Int
    ) async -> BasicChoiceSubmitResult {
        await sendBasicChoice(identity, choiceIndex: choiceIndex, isRetry: false)
    }

    func retryBasicChoice(_ identity: BasicChoicePromptIdentity) async -> BasicChoiceSubmitResult {
        guard let record = basicChoiceActions[identity.gameID],
              record.identity == identity,
              case .retryable = record.phase
        else { return .staleQuestion }
        return await sendBasicChoice(identity, choiceIndex: record.choiceIndex, isRetry: true)
    }

    private func sendBasicChoice(
        _ identity: BasicChoicePromptIdentity, choiceIndex: Int, isRetry: Bool
    ) async -> BasicChoiceSubmitResult {
        let preparation = prepareBasicChoiceSend(
            identity, choiceIndex: choiceIndex, isRetry: isRetry
        )
        guard case let .send(connection, actionAttemptID) = preparation else {
            guard case let .reject(result) = preparation else { return .retryableFailure }
            return result
        }
        return await performBasicChoiceSend(
            identity,
            choiceIndex: choiceIndex,
            connection: connection,
            actionAttemptID: actionAttemptID
        )
    }

    private func prepareBasicChoiceSend(
        _ identity: BasicChoicePromptIdentity, choiceIndex: Int, isRetry: Bool
    ) -> BasicChoiceSendPreparation {
        guard let presentation = basicChoicePresentation(for: identity.gameID),
              presentation.identity == identity
        else { return .reject(.staleQuestion) }
        if let action = basicChoiceActions[identity.gameID] {
            switch action.phase {
            case .sending, .awaitingSnapshot, .uncertain:
                return .reject(.alreadyPending)
            case .retryable where !isRetry:
                return .reject(.alreadyPending)
            case .retryable, .accepted:
                break
            }
        }
        guard isRetry ? presentation.readOnlyReason == nil : presentation.canSubmit else {
            return .reject(.readOnly)
        }
        guard let choice = presentation.choices.first(where: { $0.index == choiceIndex }),
              choice.isSupported
        else { return .reject(.unsupportedChoice) }
        guard let connection = liveGameConnections[identity.gameID],
              liveGameSessions[identity.gameID]?.attemptID == connection.attemptID
        else { return .reject(.readOnly) }

        let actionAttemptID = UUID()
        basicChoiceActions[identity.gameID] = BasicChoiceActionRecord(
            identity: identity,
            choiceIndex: choiceIndex,
            attemptID: actionAttemptID,
            connectionID: connection.connectionID,
            phase: .sending
        )
        return .send(connection: connection, actionAttemptID: actionAttemptID)
    }

    private func performBasicChoiceSend(
        _ identity: BasicChoicePromptIdentity,
        choiceIndex: Int,
        connection: LiveGameConnectionHandle,
        actionAttemptID: UUID
    ) async -> BasicChoiceSubmitResult {
        let bytes: Data
        do {
            bytes = try ContractJSON.encode(BasicChoiceAnswer(
                choice: choiceIndex,
                playerID: identity.ownerID,
                questionVersion: identity.questionVersion
            ))
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
        case .uncertain, .retryable, .accepted:
            break
        }
    }

    func reconcileBasicChoice(
        gameID: GameID, projection: BoardProjection, isRESTSnapshot: Bool
    ) {
        guard let action = basicChoiceActions[gameID] else { return }
        let current = projection.questions[action.identity.ownerID]
        let samePrompt = projection.counters.scenarioSteps == action.identity.questionVersion
            && current?.rawValue == action.identity.rawQuestion
        if !samePrompt {
            basicChoiceActions[gameID]?.phase = .accepted
        } else if isRESTSnapshot, action.phase == .uncertain {
            basicChoiceActions[gameID]?.identity = BasicChoicePromptIdentity(
                gameID: gameID,
                ownerID: action.identity.ownerID,
                questionVersion: action.identity.questionVersion,
                rawQuestion: action.identity.rawQuestion,
                sessionAttemptID: liveGameSessions[gameID]?.attemptID,
                connectionID: liveGameConnections[gameID]?.connectionID
            )
            basicChoiceActions[gameID]?.phase = .retryable(.outcomeUncertain)
        }
    }

    func handleBasicChoiceGameError(gameID: GameID, projection: BoardProjection) {
        guard let action = basicChoiceActions[gameID],
              projection.counters.scenarioSteps == action.identity.questionVersion,
              projection.questions[action.identity.ownerID]?.rawValue
              == action.identity.rawQuestion
        else { return }
        switch action.phase {
        case .sending, .awaitingSnapshot, .uncertain:
            basicChoiceActions[gameID]?.phase = .retryable(.serverRejected)
        case .retryable, .accepted:
            break
        }
    }
}
