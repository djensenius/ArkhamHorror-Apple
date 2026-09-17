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
        case (42, .playerWindowChooseOne, _):
            if try validateGatheringAtticActionWindowIfPresent(
                for: presentation
            ) {
                return nil
            }
            let hasMovement = presentation.choices.contains {
                $0.kind == .move
            }
            let hasActionWindowSemantics =
                presentation.gatheringAtticActionWindowSemantics != nil
            if hasActionWindowSemantics || hasMovement {
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
                "238a9dc09dcba4893c264eb51dd8d952fdb3488d6f8eb268a3d7b7f881f6190a"
            expectedPresentationSHA256 =
                "062d17ef4072edfa976a4ec946d7a296aaa43d5c0ee4bd5c2baed6bb3ffe3bfb"
        } else if investigation.matchesGatheringInvestigation(
            cardCode: "c01113"
        ) {
            expectedRawSHA256 =
                "d09ef3b29355240dc6663ea46c888bf99a833f916623b170634a13daf1ecdee7"
            expectedPresentationSHA256 =
                "2526973b069dfa5ac8b036696dbaa53d2f673e2acd0b992c081c7dff51a2f739"
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
