import CryptoKit
import Foundation

struct QuestionPresentationRawQuestionShape: Sendable, Equatable, Hashable {
    let kind: QuestionPresentation.Kind
    let choices: [JSONValue]

    func validateGovernedChoices(
        for presentation: QuestionPresentation
    ) throws {
        switch (
            presentation.questionVersion,
            presentation.questionKind,
            presentation.choiceCount
        ) {
        case (34, .playerWindowChooseOne, 13):
            try validateGatheringActObjectiveChoices(for: presentation)
        case (35, .chooseOne, 1):
            try validateCanonicalChoice(
                at: 0,
                expectedSHA256:
                "4e85cfd95e1abe29f08f8d1cf7eaaf817b23193b77000fe5413b02fdec6f3b7f"
            )
        default:
            return
        }
    }

    private func validateGatheringActObjectiveChoices(
        for presentation: QuestionPresentation
    ) throws {
        let rawSeal: GovernedJSONSeal
        let presentationSeal: GovernedJSONSeal
        do {
            rawSeal = try GovernedJSONSeal(.array(choices))
            let presentationValue = try ContractJSON.decode(
                JSONValue.self,
                from: ContractJSON.encode(presentation.choices)
            )
            presentationSeal = try GovernedJSONSeal(presentationValue)
        } catch {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
        guard rawSeal.canonicalSHA256 ==
            "d6ebbbb9a4bc4c2110f95a7f086d32499af07115f0f3f3d9f9a167d59f927a65",
            presentationSeal.canonicalSHA256 ==
            "5393915d65cdda2b46b860a1a3e45f56e834823b1cee5d7360528394029b768c",
            rawSeal.dynamicIDs.count == 8,
            presentationSeal.dynamicIDs == rawSeal.dynamicIDs
        else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
    }

    private func validateCanonicalChoice(
        at sourceIndex: Int,
        expectedSHA256: String
    ) throws {
        guard choices.indices.contains(sourceIndex) else {
            throw QuestionPresentationBindingError.rawChoiceMismatch(
                sourceIndex: sourceIndex
            )
        }
        let canonical: Data
        do {
            canonical = try LosslessJSONSerializer.serialize(
                choices[sourceIndex]
            )
        } catch {
            throw QuestionPresentationBindingError.rawChoiceMismatch(
                sourceIndex: sourceIndex
            )
        }
        let digest = SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == expectedSHA256 else {
            throw QuestionPresentationBindingError.rawChoiceMismatch(
                sourceIndex: sourceIndex
            )
        }
    }
}

private struct GovernedJSONSeal {
    let canonicalSHA256: String
    let dynamicIDs: [String]

    init(_ value: JSONValue) throws {
        var normalizer = GovernedUUIDNormalizer()
        let normalized = normalizer.normalize(value)
        let canonical = try LosslessJSONSerializer.serialize(normalized)
        canonicalSHA256 = SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
        dynamicIDs = normalizer.dynamicIDs
    }
}

private struct GovernedUUIDNormalizer {
    private var placeholders: [String: String] = [:]
    private(set) var dynamicIDs: [String] = []

    mutating func normalize(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .string(string):
            guard Self.isCanonicalUUID(string) else { return value }
            if let placeholder = placeholders[string] {
                return .string(placeholder)
            }
            let placeholder = "$uuid\(dynamicIDs.count)"
            placeholders[string] = placeholder
            dynamicIDs.append(string)
            return .string(placeholder)
        case let .array(elements):
            var normalized: [JSONValue] = []
            normalized.reserveCapacity(elements.count)
            for element in elements {
                normalized.append(normalize(element))
            }
            return .array(normalized)
        case let .object(object):
            var normalized: [String: JSONValue] = [:]
            normalized.reserveCapacity(object.count)
            for key in object.keys.sorted() {
                guard let child = object[key] else { continue }
                normalized[key] = normalize(child)
            }
            return .object(normalized)
        case .null, .bool, .number:
            return value
        }
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
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
        if let shape = try directQuestion(tag: tag, object: object) {
            return shape
        }
        if let shape = try derivedWrappedQuestion(tag: tag, object: object) {
            return shape
        }
        switch tag {
        case "ChooseOneAtATimeWithAuto":
            _ = try labeledChoices(object, tag: tag, kind: .chooseOneAtATime)
            return .init(kind: .unsupported, choices: [])
        case "Read":
            return try readChoices(object)
        default:
            return .init(kind: .unsupported, choices: [])
        }
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
            try labeledChoices(object, tag: tag, kind: .chooseSome)
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

    private static func readChoices(
        _ object: [String: JSONValue]
    ) throws -> QuestionPresentationRawQuestionShape {
        guard Set(object.keys) == ["tag", "flavorText", "readChoices", "readCards"],
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
