// swiftlint:disable type_body_length cyclomatic_complexity function_body_length line_length
import Foundation

struct QuestionPresentationRawQuestionShape: Sendable, Equatable, Hashable {
    let kind: QuestionPresentation.Kind
    let choices: [JSONValue]
    let rawQuestion: JSONValue

    init(
        kind: QuestionPresentation.Kind,
        choices: [JSONValue],
        rawQuestion: JSONValue = .null
    ) {
        self.kind = kind
        self.choices = choices
        self.rawQuestion = rawQuestion
    }
}

enum QuestionPresentationRawQuestionDeriver {
    static func derive(_ value: JSONValue) throws -> QuestionPresentationRawQuestionShape {
        guard case let .object(object) = value,
              case let .string(tag)? = object["tag"],
              !tag.isEmpty
        else {
            throw invalid("Raw question must be a tagged object")
        }
        let shape: QuestionPresentationRawQuestionShape
        if let shape = try directQuestion(tag: tag, object: object) {
            return .init(
                kind: shape.kind,
                choices: shape.choices,
                rawQuestion: value
            )
        } else if let wrappedShape = try derivedWrappedQuestion(
            tag: tag,
            object: object
        ) {
            shape = wrappedShape
        } else {
            switch tag {
            case "ChooseOneAtATimeWithAuto":
                shape = try oneAtATimeWithAutoChoices(object, tag: tag)
            case "ChooseOneFromEach":
                shape = try oneFromEachChoices(object)
            case "ChoosePaymentAmounts":
                shape = try noChoice(
                    object,
                    keys: ["tag", "label", "paymentAmountTargetValue", "paymentAmountChoices"],
                    kind: .choosePaymentAmounts
                )
            case "ChooseAmounts":
                shape = try noChoice(
                    object,
                    keys: ["tag", "label", "amountTargetValue", "amountChoices", "target"],
                    kind: .chooseAmounts
                )
            case "ChooseExchangeAmounts":
                // Arkham/Question.hs:248-254 derives record-field JSON with defaultOptions.
                shape = try noChoice(
                    object,
                    keys: [
                        "tag", "source", "investigator1Id",
                        "investigator1InitialAmount", "investigator2Id",
                        "investigator2InitialAmount", "token",
                    ],
                    kind: .chooseExchangeAmounts
                )
            case "ChooseDeck":
                shape = try noChoice(object, keys: ["tag"], kind: .chooseDeck)
            case "ChooseUpgradeDeck":
                shape = try noChoice(object, keys: ["tag"], kind: .chooseUpgradeDeck)
            case "ChooseJoinDeck":
                shape = try noChoice(object, keys: ["tag", "usedInvestigators"], kind: .chooseJoinDeck)
            case "ChooseOneWizard":
                shape = try wizardChoices(object)
            case "PickSupplies":
                shape = try pickSuppliesChoices(object)
            case "PickDestiny":
                shape = try noChoice(object, keys: ["tag", "drawings"], kind: .pickDestiny)
            case "DropDown":
                shape = try dropdownChoices(object)
            case "PickScenarioSettings":
                shape = try noChoice(object, keys: ["tag"], kind: .pickScenarioSettings)
            case "PickCampaignSettings":
                shape = try noChoice(object, keys: ["tag"], kind: .pickCampaignSettings)
            case "PickCampaignSpecific":
                // Arkham/Question.hs:246 encodes this positional constructor as {tag,contents}.
                shape = try positionalSpecific(object, kind: .pickCampaignSpecific)
            case "PickScenarioSpecific":
                // Arkham/Question.hs:247 encodes this positional constructor as {tag,contents}.
                shape = try positionalSpecific(object, kind: .pickScenarioSpecific)
            case "ContinueCampaign":
                shape = try noChoice(object, keys: ["tag"], kind: .continueCampaign)
            case "Read":
                shape = try readChoices(object)
            default:
                shape = .init(kind: .unsupported, choices: [])
            }
        }
        return .init(
            kind: shape.kind,
            choices: shape.choices,
            rawQuestion: value
        )
    }

    private static func directQuestion(
        tag: String,
        object: [String: JSONValue]
    ) throws -> QuestionPresentationRawQuestionShape? {
        switch tag {
        case "ChooseOne":
            try directChoices(object, keys: ["tag", "choices"], kind: .chooseOne)
        case "PlayerWindowChooseOne":
            try directChoices(
                object,
                keys: ["tag", "choices"],
                kind: .playerWindowChooseOne
            )
        case "WindowChooseOne":
            try directChoices(
                object,
                keys: ["tag", "choices"],
                kind: .windowChooseOne
            )
        case "ChooseN":
            try countedChoices(object, tag: tag, kind: .chooseN)
        case "ChooseSome":
            try directChoices(object, keys: ["tag", "choices"], kind: .chooseSome)
        case "ChooseSome1":
            try labeledChoices(object, tag: tag, kind: .chooseSome1)
        case "ChooseUpToN":
            try countedChoices(object, tag: tag, kind: .chooseUpToN)
        case "ChooseOneAtATime":
            try directChoices(
                object,
                keys: ["tag", "choices"],
                kind: .chooseOneAtATime
            )
        default:
            nil
        }
    }

    private static func derivedWrappedQuestion(
        tag: String,
        object: [String: JSONValue]
    ) throws -> QuestionPresentationRawQuestionShape? {
        switch tag {
        case "QuestionLabel":
            try wrappedQuestion(
                object,
                tag: tag,
                keys: ["tag", "label", "card", "question"],
                validate: {
                    guard case .string = $0["label"],
                          $0["card"] == .null || Self.isString($0["card"])
                    else { throw invalid("Malformed QuestionLabel wrapper") }
                }
            )
        case "PayCostQuestion":
            try wrappedQuestion(
                object,
                tag: tag,
                keys: ["tag", "cost", "question"],
                validate: {
                    guard case .object = $0["cost"] else {
                        throw invalid("Malformed PayCostQuestion wrapper")
                    }
                }
            )
        case "QuestionWithSource":
            try wrappedQuestion(
                object,
                tag: tag,
                keys: ["tag", "source", "tooltip", "question"],
                validate: {
                    guard case .object = $0["source"] else {
                        throw invalid("Malformed QuestionWithSource wrapper")
                    }
                }
            )
        default:
            nil
        }
    }

    private static func noChoice(
        _ object: [String: JSONValue],
        keys: Set<String>,
        kind: QuestionPresentation.Kind
    ) throws -> QuestionPresentationRawQuestionShape {
        guard Set(object.keys) == keys else {
            throw invalid("Malformed \(tag(of: object)) question")
        }
        return .init(kind: kind, choices: [])
    }

    private static func directChoices(
        _ object: [String: JSONValue],
        keys: Set<String>,
        kind: QuestionPresentation.Kind
    ) throws -> QuestionPresentationRawQuestionShape {
        guard Set(object.keys) == keys,
              case let .array(choices)? = object["choices"]
        else {
            throw invalid("Malformed \(tag(of: object)) question")
        }
        return .init(kind: kind, choices: choices)
    }

    private static func countedChoices(
        _ object: [String: JSONValue],
        tag: String,
        kind: QuestionPresentation.Kind
    ) throws -> QuestionPresentationRawQuestionShape {
        guard Set(object.keys) == ["tag", "amount", "choices"],
              let amount = integer(object["amount"]),
              amount >= 0
        else {
            throw invalid("Malformed \(tag) question")
        }
        return try directChoices(
            ["tag": .string(tag), "choices": object["choices"] ?? .null],
            keys: ["tag", "choices"],
            kind: kind
        )
    }

    private static func labeledChoices(
        _ object: [String: JSONValue],
        tag: String,
        kind: QuestionPresentation.Kind
    ) throws -> QuestionPresentationRawQuestionShape {
        guard Set(object.keys) == ["tag", "label", "choices"],
              case .string = object["label"]
        else {
            throw invalid("Malformed \(tag) question")
        }
        return try directChoices(
            ["tag": .string(tag), "choices": object["choices"] ?? .null],
            keys: ["tag", "choices"],
            kind: kind
        )
    }

    private static func wrappedQuestion(
        _ object: [String: JSONValue],
        tag: String,
        keys: Set<String>,
        validate: ([String: JSONValue]) throws -> Void
    ) throws -> QuestionPresentationRawQuestionShape {
        guard Set(object.keys) == keys, let question = object["question"] else {
            throw invalid("Malformed \(tag) wrapper")
        }
        try validate(object)
        return try derive(question)
    }

    private static func oneAtATimeWithAutoChoices(
        _ object: [String: JSONValue],
        tag: String
    ) throws -> QuestionPresentationRawQuestionShape {
        let shape = try labeledChoices(object, tag: tag, kind: .chooseOneAtATimeWithAuto)
        let autoChoice = JSONValue.object([
            "tag": .string("AutoChoice"),
            "label": object["label"] ?? .null,
        ])
        return .init(kind: shape.kind, choices: [autoChoice] + shape.choices)
    }

    private static func oneFromEachChoices(
        _ object: [String: JSONValue]
    ) throws -> QuestionPresentationRawQuestionShape {
        guard Set(object.keys) == ["tag", "groups"],
              case let .array(groups)? = object["groups"]
        else {
            throw invalid("Malformed ChooseOneFromEach question")
        }
        var choices: [JSONValue] = []
        for group in groups {
            guard case let .array(groupChoices) = group else {
                throw invalid("Malformed ChooseOneFromEach group")
            }
            choices.append(contentsOf: groupChoices)
        }
        return .init(kind: .chooseOneFromEach, choices: choices)
    }

    private static func wizardChoices(
        _ object: [String: JSONValue]
    ) throws -> QuestionPresentationRawQuestionShape {
        // Arkham/Question.hs:234-238 names this field wizardChoices.
        guard Set(object.keys) == ["tag", "flavorText", "wizardChoices", "confirmLabel", "backLabel"],
              case let .array(choices)? = object["wizardChoices"]
        else {
            throw invalid("Malformed ChooseOneWizard question")
        }
        return .init(kind: .chooseOneWizard, choices: choices)
    }

    private static func positionalSpecific(
        _ object: [String: JSONValue],
        kind: QuestionPresentation.Kind
    ) throws -> QuestionPresentationRawQuestionShape {
        guard Set(object.keys) == ["tag", "contents"],
              case let .array(contents)? = object["contents"],
              contents.count == 2,
              case .string = contents[0]
        else {
            throw invalid("Malformed \(tag(of: object)) question")
        }
        return .init(kind: kind, choices: [])
    }

    private static func pickSuppliesChoices(
        _ object: [String: JSONValue]
    ) throws -> QuestionPresentationRawQuestionShape {
        guard Set(object.keys) == ["tag", "pointsRemaining", "chosenSupplies", "choices", "resupply"],
              case let .array(choices)? = object["choices"]
        else {
            throw invalid("Malformed PickSupplies question")
        }
        return .init(kind: .pickSupplies, choices: choices)
    }

    private static func dropdownChoices(
        _ object: [String: JSONValue]
    ) throws -> QuestionPresentationRawQuestionShape {
        guard Set(object.keys) == ["tag", "options"],
              case let .array(options)? = object["options"]
        else {
            throw invalid("Malformed DropDown question")
        }
        return .init(kind: .dropDown, choices: options)
    }

    private static func readChoices(
        _ object: [String: JSONValue]
    ) throws -> QuestionPresentationRawQuestionShape {
        guard Set(["tag", "flavorText", "readChoices", "readCards"])
            .isSubset(of: Set(object.keys)),
            object["tag"] == .string("Read"),
            case let .object(readChoices)? = object["readChoices"],
            Set(readChoices.keys) == ["tag", "contents"],
            case let .string(tag)? = readChoices["tag"]
        else {
            throw invalid("Malformed Read question")
        }
        let choices: [JSONValue]
        switch tag {
        case "BasicReadChoices", "LeadInvestigatorMustDecide":
            guard case let .array(values)? = readChoices["contents"] else {
                throw invalid("Malformed \(tag)")
            }
            choices = values
        case "BasicReadChoicesN", "BasicReadChoicesUpToN":
            guard case let .array(contents)? = readChoices["contents"],
                  contents.count == 2,
                  let amount = integer(contents[0]),
                  amount >= 0,
                  case let .array(values) = contents[1]
            else {
                throw invalid("Malformed \(tag)")
            }
            choices = values
        default:
            throw invalid("Unknown ReadChoices constructor \(tag)")
        }
        return .init(kind: .read, choices: choices)
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        return try? LosslessJSONPrimitive.integer(value, codingPath: [])
    }

    private static func isString(_ value: JSONValue?) -> Bool {
        guard case .string = value else { return false }
        return true
    }

    private static func tag(of object: [String: JSONValue]) -> String {
        guard case let .string(tag)? = object["tag"] else { return "untagged" }
        return tag
    }

    private static func invalid(_ description: String) -> QuestionPresentationBindingError {
        .invalidRawQuestion(description)
    }
}

// swiftlint:enable type_body_length cyclomatic_complexity function_body_length line_length
