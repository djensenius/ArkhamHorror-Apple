import Foundation

struct BasicChoiceQuestionPayload: Sendable, Equatable, Hashable {
    let rawValue: JSONValue
    let state: BasicChoiceQuestionState
    let presentation: BoundQuestionPresentation?

    init(
        rawValue: JSONValue,
        state: BasicChoiceQuestionState,
        presentation: BoundQuestionPresentation? = nil
    ) {
        self.rawValue = rawValue
        self.state = state
        self.presentation = presentation
    }

    var supportedQuestion: BasicChoiceQuestion? {
        guard case let .supported(question) = state else { return nil }
        return question
    }

    var isUpdateRequired: Bool {
        if case .updateRequired = state {
            true
        } else {
            false
        }
    }

    func binding(_ presentation: BoundQuestionPresentation) -> Self {
        Self(rawValue: rawValue, state: state, presentation: presentation)
    }
}

extension BasicChoiceQuestionPayload: Codable {
    init(from decoder: any Decoder) throws {
        let rawValue = try JSONValue(from: decoder)
        self.rawValue = rawValue
        state = BasicChoiceParser.parseQuestion(rawValue)
        presentation = nil
    }

    func encode(to encoder: any Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}
