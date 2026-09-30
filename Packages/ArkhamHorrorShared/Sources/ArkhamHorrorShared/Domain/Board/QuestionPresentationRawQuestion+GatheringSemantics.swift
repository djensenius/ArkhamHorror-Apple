import CryptoKit
import Foundation

extension QuestionPresentationRawQuestionShape {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func validateGovernedChoices(
        for presentation: QuestionPresentation
    ) throws -> QuestionPresentation.GovernedSource? {
        let rawEncounterDrawActorID = encounterDeckDrawActorID()
        let hasEncounterDrawDescriptor = presentation.choices.contains {
            $0.kind == .drawEncounterCard
        }
        if rawEncounterDrawActorID != nil || hasEncounterDrawDescriptor {
            try validateEncounterDeckDraw(
                for: presentation,
                rawActorID: rawEncounterDrawActorID
            )
            return nil
        }
        if try validateTreacheryForcedAbilities(for: presentation) {
            return nil
        }

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
                "5fc1b0eece8513294d0abffec2e10780d05c4b58a3ef7fdd9c6a63df5e1e68e3",
                expectedPresentationSHA256:
                "188ba6aa88e9a29e26073a1dc4ac3e4613b7aae574cd5e145648cc110d5b231f",
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
        case (40, .chooseOne, 1):
            try validateGatheringStartSkillTest(for: presentation)
            return nil
        case (40, .playerWindowChooseOne, 1):
            try validateGatheringEndTurn(for: presentation)
            return nil
        case (41, .chooseOne, 1):
            try validateGatheringApplySkillTestResults(for: presentation)
            return nil
        case (42, .playerWindowChooseOne, 1):
            try validateGatheringEndTurn(for: presentation)
            return nil
        case (42, .playerWindowChooseOne, 12),
             (42, .playerWindowChooseOne, 13):
            guard try validateGatheringAtticActionWindowIfPresent(
                for: presentation
            ) else {
                throw QuestionPresentationBindingError
                    .governedChoicesMismatch
            }
            return nil
        default:
            return nil
        }
    }

    private func encounterDeckDrawActorID() -> String? {
        guard case let .object(root) = rawQuestion,
              root["tag"] == .string("ChooseOne"),
              kind == .chooseOne,
              choices.count == 1,
              case let .object(rawChoice) = choices[0],
              case let .drawEncounterCard(investigatorID, _)? =
              BasicChoiceParser.parseEncounterDeckDraw(
                  rawChoice,
                  kind: .chooseOne,
                  index: 0
              )
        else { return nil }
        return investigatorID.rawValue.rawValue
    }

    private func validateEncounterDeckDraw(
        for presentation: QuestionPresentation,
        rawActorID: String?
    ) throws {
        guard let rawActorID,
              kind == .chooseOne,
              presentation.questionKind == .chooseOne,
              presentation.choiceCount == 1,
              presentation.choices == [.encounterDeckDraw(actorID: rawActorID)]
        else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
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
            "fd794c54be4a1df88577cc0586b17e0d100712249aaa610944ac9154710ccca6",
            presentationSeal.canonicalSHA256 ==
            "8bd42efce19180f477d26ea09a044c4b9d34602cbbc511a92fac64bf17427e9a",
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
                "9980f8cbe880c8475d3896b3d72d4c650dc1bcc3a63aabab44c8e85ac321cf15",
                expectedPresentationSHA256:
                "ac33028ad167ce52c4cefd7b27ca6a27709f2c390f71a101f70e0f5a523c71ba",
                requireMatchingDynamicIDs: true
            )
        } else if isAttic {
            _ = try validateGatheringQuestion(
                for: presentation,
                expectedRawSHA256:
                "0cb42ef0f51335143c23a5e101acee98f99c159c14272af6476b1b6d3090a799",
                expectedPresentationSHA256:
                "179f9b70025de64cc396f28b636ba49646fbe976e4222f0b4e4889ff6588b798",
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
                "b0476021e1e7bb3498147e10e171f77b54b8ae1b73f962256b32c642868c0448"
            )
        } else if presentation.choices == [.gatheringAtticHorrorAssignment] {
            cardCode = "c01113"
            rawSeal = try validateGatheringQuestion(
                for: presentation,
                expectedRawSHA256:
                "f3cb6bba8328b857d6ee9e99d9eae4b6a82cc196625752fe4a7b8b55c5562f78",
                expectedPresentationSHA256:
                "d53b03ec619de0966921728035e18fb068c410ef917c4ae10087385b8a61857e"
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

    // swiftlint:disable:next function_body_length
    private func validateGatheringPostEntryChoices(
        for presentation: QuestionPresentation
    ) throws {
        let investigations = presentation.choices.filter {
            $0.matchesGatheringInvestigation(
                cardCode: "c01114"
            ) || $0.matchesGatheringInvestigation(
                cardCode: "c01113"
            )
        }
        let hallways = presentation.choices.filter {
            $0.matchesGatheringHallwayMovement()
        }
        guard choices.indices.contains(10),
              presentation.choices.indices.contains(10),
              investigations.count == 1,
              hallways.count == 1,
              let investigation = investigations.first,
              let hallway = hallways.first,
              Set([
                  investigation.sourceIndex,
                  hallway.sourceIndex,
              ]) == [9, 10]
        else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
        let expectedRawSHA256: String
        let expectedPresentationSHA256: String
        if investigation.matchesGatheringInvestigation(
            cardCode: "c01114"
        ) {
            expectedRawSHA256 =
                "c19f7242a65dbfef89d57fbd09515ed51171f124699de8c826102640377093a4"
            expectedPresentationSHA256 =
                "188ba6aa88e9a29e26073a1dc4ac3e4613b7aae574cd5e145648cc110d5b231f"
        } else if investigation.matchesGatheringInvestigation(
            cardCode: "c01113"
        ) {
            expectedRawSHA256 =
                "1db076f96e888332db1a92f434f9c94e5d60c166603a8b6420c73c2e338887c7"
            expectedPresentationSHA256 =
                "64b1c25fd462fc61b04bc67fa8ffc797f29253fc2990136e373d39907ec8fa0a"
        } else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }

        let rawSeal: GovernedJSONSeal
        let presentationSeal: GovernedJSONSeal
        do {
            rawSeal = try GovernedJSONSeal(
                .array(
                    canonicalPostEntryRawChoices(
                        investigationSourceIndex:
                        investigation.sourceIndex,
                        hallwaySourceIndex: hallway.sourceIndex
                    )
                )
            )
            presentationSeal = try makePresentationSeal(
                for: canonicalPostEntryPresentationChoices(
                    presentation.choices,
                    investigation: investigation,
                    hallway: hallway
                )
            )
        } catch {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
        guard rawSeal.canonicalSHA256 == expectedRawSHA256,
              presentationSeal.canonicalSHA256 ==
              expectedPresentationSHA256,
              rawSeal.dynamicIDs.count == 8,
              rawSeal.dynamicIDs == presentationSeal.dynamicIDs
        else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
    }

    private func canonicalPostEntryRawChoices(
        investigationSourceIndex: Int,
        hallwaySourceIndex: Int
    ) -> [JSONValue] {
        var result = choices
        result[9] = choices[investigationSourceIndex]
        result[10] = choices[hallwaySourceIndex]
        return result
    }

    private func canonicalPostEntryPresentationChoices(
        _ choices: [QuestionPresentation.Choice],
        investigation: QuestionPresentation.Choice,
        hallway: QuestionPresentation.Choice
    ) -> [QuestionPresentation.Choice] {
        var result = choices
        result[9] = investigation.replacingSourceIndex(9)
        result[10] = hallway.replacingSourceIndex(10)
        return result
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
