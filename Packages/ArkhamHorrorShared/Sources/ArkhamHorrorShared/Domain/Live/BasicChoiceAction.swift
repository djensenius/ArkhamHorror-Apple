import Foundation

enum LiveGameParticipantIdentity: Sendable, Equatable {
    case participant(PlayerID)
    case spectator
}

struct BasicChoicePromptIdentity: Sendable, Equatable, Hashable {
    let gameID: GameID
    let ownerID: PlayerID
    let questionVersion: Int
    let rawQuestion: JSONValue
    let sessionAttemptID: UUID?
    let connectionID: UUID?

    var promptKey: BasicChoicePromptKey {
        BasicChoicePromptKey(
            gameID: gameID,
            ownerID: ownerID,
            questionVersion: questionVersion,
            rawQuestion: rawQuestion
        )
    }
}

/// Authoritative prompt identity, deliberately excluding replaceable transport identity.
struct BasicChoicePromptKey: Sendable, Equatable, Hashable {
    let gameID: GameID
    let ownerID: PlayerID
    let questionVersion: Int
    let rawQuestion: JSONValue
}

enum BasicChoiceReadOnlyReason: Sendable, Equatable {
    case spectator
    case anotherPlayer
    case legacyServer
    case updateRequired
    case disconnected
}

enum BasicChoiceRetryReason: Sendable, Equatable {
    case transportFailure
    case serverRejected
    case outcomeUncertain
}

enum BasicChoiceActionPhase: Sendable, Equatable {
    case sending
    case awaitingSnapshot
    case uncertain
    case retryable(BasicChoiceRetryReason)
}

struct BasicChoicePromptPresentation: Sendable, Equatable {
    let identity: BasicChoicePromptIdentity
    let question: BasicChoiceQuestionState
    let readOnlyReason: BasicChoiceReadOnlyReason?
    let actionPhase: BasicChoiceActionPhase?
    let actionChoiceIndex: Int?
    let serverFeedback: String?

    var ownerID: PlayerID {
        identity.ownerID
    }

    var questionVersion: Int {
        identity.questionVersion
    }

    var choices: [BasicChoice] {
        question.supportedQuestion?.choices ?? []
    }

    var isAuthorized: Bool {
        readOnlyReason == nil
    }

    var canSubmit: Bool {
        guard isAuthorized else { return false }
        switch actionPhase {
        case .sending, .awaitingSnapshot, .uncertain:
            return false
        case nil:
            return true
        case .retryable:
            return false
        }
    }

    var statusMessage: String? {
        switch actionPhase {
        case .sending:
            return "Sending choice…"
        case .awaitingSnapshot:
            return "Choice sent. Waiting for the game to update…"
        case .uncertain:
            return "Connection lost while sending. Reconnect to check the outcome."
        case .retryable(.transportFailure):
            return "The choice could not be sent. Try again."
        case .retryable(.serverRejected):
            return "The server rejected this choice. Try again."
        case .retryable(.outcomeUncertain):
            return "The outcome is uncertain. Review the prompt, then retry manually."
        case nil:
            break
        }
        switch readOnlyReason {
        case .spectator:
            return "Spectators can view this prompt but cannot answer it."
        case .anotherPlayer:
            return "Waiting for another player to answer."
        case .legacyServer:
            return "Update the server before answering this prompt."
        case .updateRequired:
            return "This prompt requires a newer app version."
        case .disconnected:
            return "Reconnect before answering this prompt."
        case nil:
            return nil
        }
    }

    var canRetry: Bool {
        guard readOnlyReason == nil else { return false }
        if case .retryable = actionPhase {
            return true
        }
        return false
    }
}

enum BasicChoiceSubmitResult: Sendable, Equatable {
    case sentAwaitingSnapshot
    case alreadyPending
    case retryableFailure
    case staleQuestion
    case readOnly
    case unsupportedChoice
}

struct BasicChoiceActionRecord: Sendable, Equatable {
    var identity: BasicChoicePromptIdentity
    let choiceIndex: Int
    let attemptID: UUID
    let connectionID: UUID
    var phase: BasicChoiceActionPhase
}

struct LiveGameConnectionHandle: Sendable {
    let attemptID: UUID
    let connectionID: UUID
    let connection: any GameSocketConnection
}
