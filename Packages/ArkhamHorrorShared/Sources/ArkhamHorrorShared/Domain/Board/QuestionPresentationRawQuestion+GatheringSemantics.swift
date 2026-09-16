import CryptoKit
import Foundation

extension QuestionPresentationRawQuestionShape {
    func validateGovernedChoices(
        for presentation: QuestionPresentation
    ) throws -> QuestionPresentation.GovernedSource? {
        switch (
            presentation.questionVersion,
            presentation.questionKind,
            presentation.choiceCount
        ) {
        case (34, .playerWindowChooseOne, 13):
            try validateGatheringActObjectiveChoices(for: presentation)
            return nil
        case (35, .chooseOne, 1):
            try validateCanonicalChoice(
                at: 0,
                expectedSHA256:
                "4e85cfd95e1abe29f08f8d1cf7eaaf817b23193b77000fe5413b02fdec6f3b7f"
            )
            return nil
        case (36, .playerWindowChooseOne, 12):
            _ = try validateGatheringQuestion(
                for: presentation,
                expectedRawSHA256:
                "ba3e81d7664e7222180951b494d0b12f80ba3fcfb12d9cdabf355d635349ab92",
                expectedPresentationSHA256:
                "07930689d4d3669128a9ce879ee0c53b786e1928b1d653431f29ab0c92e5a5eb",
                requireMatchingDynamicIDs: true
            )
            return nil
        case (37, .windowChooseOne, 1):
            try validateGatheringForcedAbility(for: presentation)
            return nil
        case (38, .chooseOne, 1):
            return try validateGatheringAssignment(for: presentation)
        case (39, .playerWindowChooseOne, 11):
            try validateGatheringPostEntryChoices(for: presentation)
            return nil
        default:
            return nil
        }
    }

    private func validateGatheringActObjectiveChoices(
        for presentation: QuestionPresentation
    ) throws {
        let rawSeal: GovernedJSONSeal
        let presentationSeal: GovernedJSONSeal
        do {
            rawSeal = try GovernedJSONSeal(.array(choices))
            presentationSeal = try makePresentationSeal(for: presentation)
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

    private func validateGatheringForcedAbility(
        for presentation: QuestionPresentation
    ) throws {
        let isCellar = presentation.choices.count == 1
            && presentation.choices[0]
            .matchesGatheringForcedAbility(cardCode: "c01114")
        let isAttic = presentation.choices.count == 1
            && presentation.choices[0]
            .matchesGatheringForcedAbility(cardCode: "c01113")
        if isCellar {
            _ = try validateGatheringQuestion(
                for: presentation,
                expectedRawSHA256:
                "3401f36678546880ddd3a05ba238e16bdf59f280e65ba37cc6711557c74b002e",
                expectedPresentationSHA256:
                "2a9fdaddf69c7bd6d7758df49d33b798144e9be442d13373c868b83eac6185a8",
                requireMatchingDynamicIDs: true
            )
        } else if isAttic {
            _ = try validateGatheringQuestion(
                for: presentation,
                expectedRawSHA256:
                "f06baff35dd9222d91aa85b03cc8824506c09331895ccad20155fdae2e92c2c8",
                expectedPresentationSHA256:
                "8ee988b07f10c167599bb96c1b825bcc2d85cd7d5b262035153956b7b4e4950c",
                requireMatchingDynamicIDs: true
            )
        } else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
    }

    private func validateGatheringAssignment(
        for presentation: QuestionPresentation
    ) throws -> QuestionPresentation.GovernedSource {
        let cardCode: String
        let rawSeal: GovernedJSONSeal
        if presentation.choices == [.gatheringCellarDamageAssignment] {
            cardCode = "c01114"
            rawSeal = try validateGatheringQuestion(
                for: presentation,
                expectedRawSHA256:
                "1f016c224713e192da6a4919ac1194b79445b83e8fb1011c20a674f333664a67",
                expectedPresentationSHA256:
                "928744a66d3b488055f6edcfb222361088b0e7936e0c6ef913df8c68046d8fdf"
            )
        } else if presentation.choices == [.gatheringAtticHorrorAssignment] {
            cardCode = "c01113"
            rawSeal = try validateGatheringQuestion(
                for: presentation,
                expectedRawSHA256:
                "f3cb6bba8328b857d6ee9e99d9eae4b6a82cc196625752fe4a7b8b55c5562f78",
                expectedPresentationSHA256:
                "2d9c62f296966868f7f1d22779f746bd690c586bf98e89130f41d537236f5068"
            )
        } else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
        guard rawSeal.dynamicIDs.count == 1,
              let locationID = rawSeal.dynamicIDs.first,
              LocationID(
                  codingKey: AnyCodingKey(stringValue: locationID)
              ) != nil
        else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
        return QuestionPresentation.GovernedSource(
            entity: .init(kind: .location, id: locationID),
            cardCode: cardCode
        )
    }

    private func validateGatheringPostEntryChoices(
        for presentation: QuestionPresentation
    ) throws {
        guard choices.indices.contains(10),
              presentation.choices.indices.contains(10)
        else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
        let investigation = presentation.choices[9]
        let expectedRawSHA256: String
        let expectedPresentationSHA256: String
        if investigation.matchesGatheringInvestigation(
            cardCode: "c01114"
        ) {
            expectedRawSHA256 =
                "e903baf29be226df9df84912619d059f38fcc5badae625b7af7d55c6dffbc463"
            expectedPresentationSHA256 =
                "1279a99e331c69e8a9978ad3f43663e55dde5cdb89e1b6db8d877fab9eb617f0"
        } else if investigation.matchesGatheringInvestigation(
            cardCode: "c01113"
        ) {
            expectedRawSHA256 =
                "b6b4a5aa36617b1d93821a800d33668419bef179ad8f6ba779950f0d9ecf1432"
            expectedPresentationSHA256 =
                "0f9fcbfb608d2867faddbee0f7d1aad54de9e7449e2bc3442d474326f912e829"
        } else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }

        let rawSeal: GovernedJSONSeal
        let presentationSeal: GovernedJSONSeal
        do {
            rawSeal = try GovernedJSONSeal(
                .array(Array(choices[9 ... 10]))
            )
            presentationSeal = try makePresentationSeal(
                for: Array(presentation.choices[9 ... 10])
            )
        } catch {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
        guard rawSeal.canonicalSHA256 == expectedRawSHA256,
              presentationSeal.canonicalSHA256 ==
              expectedPresentationSHA256,
              rawSeal.dynamicIDs.count == 2,
              rawSeal.dynamicIDs == presentationSeal.dynamicIDs
        else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
    }

    private func validateGatheringQuestion(
        for presentation: QuestionPresentation,
        expectedRawSHA256: String,
        expectedPresentationSHA256: String,
        expectedRawDynamicIDs: [String]? = nil,
        requireMatchingDynamicIDs: Bool = false
    ) throws -> GovernedJSONSeal {
        let rawSeal: GovernedJSONSeal
        let presentationSeal: GovernedJSONSeal
        do {
            rawSeal = try GovernedJSONSeal(rawQuestion)
            presentationSeal = try makePresentationSeal(for: presentation)
        } catch {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
        guard rawSeal.canonicalSHA256 == expectedRawSHA256,
              presentationSeal.canonicalSHA256 == expectedPresentationSHA256,
              expectedRawDynamicIDs.map({ rawSeal.dynamicIDs == $0 }) ?? true,
              !requireMatchingDynamicIDs
              || rawSeal.dynamicIDs == presentationSeal.dynamicIDs
        else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
        return rawSeal
    }

    private func makePresentationSeal(
        for presentation: QuestionPresentation
    ) throws -> GovernedJSONSeal {
        try makePresentationSeal(for: presentation.choices)
    }

    private func makePresentationSeal(
        for choices: [QuestionPresentation.Choice]
    ) throws -> GovernedJSONSeal {
        let value = try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(choices)
        )
        return try GovernedJSONSeal(value)
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
