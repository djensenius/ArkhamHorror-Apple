import Foundation

struct PickDestinyPromptPresentation: Sendable, Equatable {
    struct Row: Sendable, Equatable {
        let scenarioTitle: String
        let tarotTitle: String
    }

    let title: String
    let instructions: String
    let doneLabel: String
    let drawings: [QuestionPresentation.DestinyDrawing]
    let rows: [Row]
}

enum PickDestinyPromptResolution: Sendable, Equatable {
    case resolved(PickDestinyPromptPresentation)
    case unavailable(StoryUnavailableReason)

    var presentation: PickDestinyPromptPresentation? {
        guard case let .resolved(presentation) = self else { return nil }
        return presentation
    }

    var unavailableReason: StoryUnavailableReason? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }
}

enum PickDestinySelectionRules {
    static func requiredReversedCount(for drawingCount: Int) -> Int {
        (drawingCount + 1) / 2
    }

    static func reversedCount(in drawings: [QuestionPresentation.DestinyDrawing]) -> Int {
        drawings.filter { $0.tarot.facing == .reversed }.count
    }

    static func hasRequiredReversedCount(
        _ drawings: [QuestionPresentation.DestinyDrawing]
    ) -> Bool {
        reversedCount(in: drawings) == requiredReversedCount(for: drawings.count)
    }

    static func matchesPublishedSequence(
        _ submitted: [QuestionPresentation.DestinyDrawing],
        published: [QuestionPresentation.DestinyDrawing]
    ) -> Bool {
        guard submitted.count == published.count else { return false }
        return zip(submitted, published).allSatisfy { submitted, published in
            submitted.scenario == published.scenario
                && submitted.tarot.arcana == published.tarot.arcana
        }
    }

    static func canSubmit(
        _ submitted: [QuestionPresentation.DestinyDrawing],
        published: [QuestionPresentation.DestinyDrawing]
    ) -> Bool {
        matchesPublishedSequence(submitted, published: published)
            && hasRequiredReversedCount(submitted)
    }
}
