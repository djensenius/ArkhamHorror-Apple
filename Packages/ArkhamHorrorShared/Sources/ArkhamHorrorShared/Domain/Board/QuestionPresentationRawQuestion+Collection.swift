import Foundation

extension QuestionPresentationRawQuestionDeriver {
    /// Schema 0.1.57 `ChooseFromCollection` (Arkham/Question.hs:188, defaultOptions record
    /// encoding): one pick from `cardCodes`, answered by the picked code's index
    /// (Entity/Answer.hs:935), so the card codes are the raw choices.
    static func collectionChoices(
        _ object: [String: JSONValue]
    ) throws -> QuestionPresentationRawQuestionShape {
        let required: Set = ["tag", "investigatorId", "source", "cardCodes"]
        guard required.isSubset(of: Set(object.keys)),
              case .string? = object["investigatorId"],
              case .object? = object["source"],
              case let .array(cardCodes)? = object["cardCodes"],
              cardCodes.allSatisfy(isCardCode)
        else {
            throw QuestionPresentationBindingError.invalidRawQuestion(
                "Malformed ChooseFromCollection question"
            )
        }
        return .init(kind: .chooseFromCollection, choices: cardCodes)
    }

    private static func isCardCode(_ value: JSONValue) -> Bool {
        if case .string = value {
            return true
        }
        return false
    }
}
