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
    /// The complete story outcome captured from one immutable catalog snapshot. This exact
    /// value drives rendering, focus, accessibility, controller dispatch, and send fencing.
    let storyResolution: StoryResolution?
    let readOnlyReason: BasicChoiceReadOnlyReason?
    let actionPhase: BasicChoiceActionPhase?
    let actionChoiceIndex: Int?
    let serverFeedback: String?
    let catalogRetry: BasicChoiceCatalogRetryPresentation?

    init(
        identity: BasicChoicePromptIdentity,
        question: BasicChoiceQuestionState,
        storyResolution: StoryResolution? = nil,
        readOnlyReason: BasicChoiceReadOnlyReason?,
        actionPhase: BasicChoiceActionPhase?,
        actionChoiceIndex: Int?,
        serverFeedback: String?,
        catalogRetry: BasicChoiceCatalogRetryPresentation? = nil
    ) {
        self.identity = identity
        self.question = question
        self.storyResolution = storyResolution ?? question.supportedQuestion?.story.map {
            StoryNarrativeLocalization.resolve(
                $0.flavorText,
                resolver: nil,
                catalogUnavailability: .catalog(.notAdvertised)
            )
        }
        self.readOnlyReason = readOnlyReason
        self.actionPhase = actionPhase
        self.actionChoiceIndex = actionChoiceIndex
        self.serverFeedback = serverFeedback
        self.catalogRetry = catalogRetry
    }

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

    var isStoryAvailable: Bool {
        guard question.supportedQuestion?.kind == .read else { return true }
        return storyResolution?.isResolved == true
    }

    var canSubmit: Bool {
        guard isAuthorized, isStoryAvailable else { return false }
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
        if let reason = storyResolution?.unavailableReason {
            return reason.announcement
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
        guard readOnlyReason == nil, isStoryAvailable else { return false }
        if case .retryable = actionPhase {
            return true
        }
        return false
    }

    var canRetryCatalog: Bool {
        catalogRetry != nil
    }
}

/// Fences a catalog retry to one profile, load generation, and still-current prompt.
struct BasicChoiceCatalogRetryPresentation: Sendable, Equatable {
    let profileID: UUID
    let catalogGeneration: Int
    let promptKey: BasicChoicePromptKey
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
    var connectionID: UUID
    var phase: BasicChoiceActionPhase
}

struct LiveGameConnectionHandle: Sendable {
    let attemptID: UUID
    let connectionID: UUID
    let connection: any GameSocketConnection
}
