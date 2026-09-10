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

/// One localized choice label captured from the same immutable catalog snapshot used by
/// every prompt surface. Raw wire keys are never a presentation fallback.
enum BasicChoiceLabelResolution: Sendable, Equatable {
    case resolved(String)
    case unavailable(StoryUnavailableReason)

    var title: String? {
        guard case let .resolved(value) = self else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var unavailableReason: StoryUnavailableReason? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }

    var isResolved: Bool {
        title != nil
    }

    var announcement: String {
        guard case let .unavailable(reason) = self else { return "" }
        switch reason {
        case .loading:
            return "The text for this choice is still loading."
        case .catalog:
            return "The text for this choice is unavailable from this server."
        case .imagePipelineUnavailable, .imageSourceLoading:
            return reason.announcement
        case .missingKey, .unsupportedEntry:
            return "This server publishes no usable text for this choice."
        case .linkCycle, .tooComplex:
            return "The text for this choice could not be safely displayed."
        case .missingVariable, .unsupportedVariableValue:
            return "The text for this choice needs a value this app cannot display."
        }
    }
}

struct BasicChoicePromptPresentation: Sendable, Equatable {
    let identity: BasicChoicePromptIdentity
    let question: BasicChoiceQuestionState
    /// The complete story outcome captured from one immutable catalog snapshot. This exact
    /// value drives rendering, focus, accessibility, controller dispatch, and send fencing.
    let storyResolution: StoryResolution?
    /// Localized labels keyed by authoritative source index. Missing entries fail closed for
    /// choices whose wire constructor requires deployment-owned text.
    let choiceLabelResolutions: [Int: BasicChoiceLabelResolution]
    let readOnlyReason: BasicChoiceReadOnlyReason?
    let actionPhase: BasicChoiceActionPhase?
    let actionChoiceIndex: Int?
    let serverFeedback: String?
    let catalogRetry: BasicChoiceCatalogRetryPresentation?

    init(
        identity: BasicChoicePromptIdentity,
        question: BasicChoiceQuestionState,
        storyResolution: StoryResolution? = nil,
        choiceLabelResolutions: [Int: BasicChoiceLabelResolution]? = nil,
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
        if let choiceLabelResolutions {
            self.choiceLabelResolutions = choiceLabelResolutions
        } else {
            var defaults: [Int: BasicChoiceLabelResolution] = [:]
            let localizableChoices = question.supportedQuestion?.choices.filter {
                $0.localizationKey != nil
            } ?? []
            for choice in localizableChoices {
                defaults[choice.index] = .unavailable(.catalog(.notAdvertised))
            }
            self.choiceLabelResolutions = defaults
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

    func isChoiceActionable(_ choice: BasicChoice, in projection: BoardProjection) -> Bool {
        projection.isChoiceActionable(
            choice,
            ownerID: ownerID,
            storyResolution: storyResolution,
            labelResolution: choiceLabelResolutions[choice.index]
        )
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
    enum Scope: Sendable, Equatable {
        case catalog
        case images
        case localImagePipeline
    }

    let profileID: UUID
    let catalogGeneration: Int
    let promptKey: BasicChoicePromptKey
    let scope: Scope

    init(
        profileID: UUID, catalogGeneration: Int, promptKey: BasicChoicePromptKey,
        scope: Scope = .catalog
    ) {
        self.profileID = profileID
        self.catalogGeneration = catalogGeneration
        self.promptKey = promptKey
        self.scope = scope
    }

    var title: String {
        switch scope {
        case .catalog: "Retry prompt text"
        case .images: "Retry story images"
        case .localImagePipeline: "Retry image support"
        }
    }

    var accessibilityHint: String {
        switch scope {
        case .catalog: "Downloads and verifies this server's text catalog again."
        case .images: "Reloads the story image source without downloading the verified text again."
        case .localImagePipeline:
            "Initializes this app's local image cache and reloads the story image source."
        }
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
    var connectionID: UUID
    var phase: BasicChoiceActionPhase
}

struct LiveGameConnectionHandle: Sendable {
    let attemptID: UUID
    let connectionID: UUID
    let connection: any GameSocketConnection
}
