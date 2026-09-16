import CryptoKit
import Foundation

extension QuestionPresentationRawQuestionShape {
    func makePresentationSeal(
        for presentation: QuestionPresentation
    ) throws -> GovernedJSONSeal {
        try makePresentationSeal(for: presentation.choices)
    }

    func makePresentationSeal(
        for choices: [QuestionPresentation.Choice]
    ) throws -> GovernedJSONSeal {
        let value = try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(choices)
        )
        return try GovernedJSONSeal(value)
    }
}

extension QuestionPresentation.Choice {
    func replacingSourceIndex(_ sourceIndex: Int) -> Self {
        Self(
            sourceIndex: sourceIndex,
            kind: kind,
            actorID: actorID,
            entity: entity,
            label: label,
            ability: ability,
            cost: cost
        )
    }
}

struct GovernedJSONSeal {
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
