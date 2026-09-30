extension QuestionPresentationRawQuestionShape {
    func validateGatheringAtticActionWindowIfPresent(
        for presentation: QuestionPresentation
    ) throws -> Bool {
        do {
            return try validateGatheringAtticActionWindow(
                for: presentation
            )
        } catch {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
    }

    func validateGatheringStartSkillTest(
        for presentation: QuestionPresentation
    ) throws {
        guard choices == [
            .object([
                "investigatorId": .string("c01001"),
                "tag": .string("StartSkillTestButton"),
            ]),
        ],
            presentation.choices == [.gatheringStartSkillTest]
        else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
    }

    func validateGatheringApplySkillTestResults(
        for presentation: QuestionPresentation
    ) throws {
        guard choices == [
            .object([
                "tag": .string("SkillTestApplyResultsButton"),
            ]),
        ],
            presentation.choices == [.gatheringApplySkillTestResults]
        else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
    }

    func validateGatheringEndTurn(
        for presentation: QuestionPresentation
    ) throws {
        guard choices == [
            .object([
                "investigatorId": .string("c01001"),
                "messages": .array([
                    .object([
                        "contents": .string("c01001"),
                        "tag": .string("ChooseEndTurn"),
                    ]),
                ]),
                "tag": .string("EndTurnButton"),
            ]),
        ],
            presentation.choices == [.gatheringEndTurn(sourceIndex: 0)]
        else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
    }

    // swiftlint:disable:next function_body_length
    private func validateGatheringAtticActionWindow(
        for presentation: QuestionPresentation
    ) throws -> Bool {
        guard presentation.choiceCount == presentation.choices.count,
              presentation.choices.map(\.sourceIndex) ==
              Array(presentation.choices.indices)
        else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
        let expectedSeals: GatheringAtticActionWindowExpectedSeals
        switch choices.count {
        case 12:
            expectedSeals = GatheringAtticActionWindowExpectedSeals(
                rawSHA256:
                "c0c6386b6f305d3a4199192074232b8c02009fc62ee34b796e7af873bd6ec874",
                presentationSHA256:
                "e25073d730857bf50587f0e2192c1446b97a1813d59712b7a8345b2a481f865b",
                dynamicIDCount: 9
            )
        case 13:
            expectedSeals = GatheringAtticActionWindowExpectedSeals(
                rawSHA256:
                "0e82aef042eb937bcecdc583305cda643651390125ce771293851aeae0354094",
                presentationSHA256:
                "06e909dfe60b1117e554eacdefd118dde13b8dabab1f68c7bd895d4f9d63ec6e",
                dynamicIDCount: 10
            )
        default:
            return false
        }
        let firstRoleSourceIndex = choices.count - 3
        let candidates = [
            GatheringAtticActionWindowRawRoles(
                atticMovement: firstRoleSourceIndex,
                hallwayInvestigation: firstRoleSourceIndex + 1,
                cellarMovement: firstRoleSourceIndex + 2
            ),
            GatheringAtticActionWindowRawRoles(
                atticMovement: firstRoleSourceIndex,
                hallwayInvestigation: firstRoleSourceIndex + 2,
                cellarMovement: firstRoleSourceIndex + 1
            ),
            GatheringAtticActionWindowRawRoles(
                atticMovement: firstRoleSourceIndex + 1,
                hallwayInvestigation: firstRoleSourceIndex,
                cellarMovement: firstRoleSourceIndex + 2
            ),
            GatheringAtticActionWindowRawRoles(
                atticMovement: firstRoleSourceIndex + 1,
                hallwayInvestigation: firstRoleSourceIndex + 2,
                cellarMovement: firstRoleSourceIndex
            ),
            GatheringAtticActionWindowRawRoles(
                atticMovement: firstRoleSourceIndex + 2,
                hallwayInvestigation: firstRoleSourceIndex,
                cellarMovement: firstRoleSourceIndex + 1
            ),
            GatheringAtticActionWindowRawRoles(
                atticMovement: firstRoleSourceIndex + 2,
                hallwayInvestigation: firstRoleSourceIndex + 1,
                cellarMovement: firstRoleSourceIndex
            ),
        ]
        var matches: [(
            roles: GatheringAtticActionWindowRawRoles,
            seal: GovernedJSONSeal
        )] = []
        for roles in candidates {
            let seal = try GovernedJSONSeal(
                .array(canonicalRawChoices(roles: roles))
            )
            let matchesExpectedRawSeal = seal.canonicalSHA256 ==
                expectedSeals.rawSHA256
            if matchesExpectedRawSeal {
                matches.append((roles, seal))
            }
        }
        guard matches.count <= 1 else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
        guard let match = matches.first else { return false }

        let rawSeal: GovernedJSONSeal
        let presentationSeal: GovernedJSONSeal
        do {
            rawSeal = match.seal
            presentationSeal = try makePresentationSeal(
                for: canonicalPresentationChoices(
                    presentation.choices,
                    roles: match.roles
                )
            )
        } catch {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
        guard rawSeal.canonicalSHA256 ==
            expectedSeals.rawSHA256,
            presentationSeal.canonicalSHA256 ==
            expectedSeals.presentationSHA256,
            rawSeal.dynamicIDs.count == expectedSeals.dynamicIDCount,
            rawSeal.dynamicIDs == presentationSeal.dynamicIDs
        else {
            throw QuestionPresentationBindingError.governedChoicesMismatch
        }
        return true
    }

    private func canonicalRawChoices(
        roles: GatheringAtticActionWindowRawRoles
    ) -> [JSONValue] {
        var result = choices
        let firstRoleSourceIndex = choices.count - 3
        result[firstRoleSourceIndex] = choices[roles.atticMovement]
        result[firstRoleSourceIndex + 1] =
            choices[roles.hallwayInvestigation]
        result[firstRoleSourceIndex + 2] = choices[roles.cellarMovement]
        return result
    }

    private func canonicalPresentationChoices(
        _ choices: [QuestionPresentation.Choice],
        roles: GatheringAtticActionWindowRawRoles
    ) -> [QuestionPresentation.Choice] {
        var result = choices
        let firstRoleSourceIndex = choices.count - 3
        result[firstRoleSourceIndex] = choices[roles.atticMovement]
            .replacingSourceIndex(firstRoleSourceIndex)
        result[firstRoleSourceIndex + 1] =
            choices[roles.hallwayInvestigation]
                .replacingSourceIndex(firstRoleSourceIndex + 1)
        result[firstRoleSourceIndex + 2] = choices[roles.cellarMovement]
            .replacingSourceIndex(firstRoleSourceIndex + 2)
        return result
    }
}

private struct GatheringAtticActionWindowRawRoles {
    let atticMovement: Int
    let hallwayInvestigation: Int
    let cellarMovement: Int
}

private struct GatheringAtticActionWindowExpectedSeals {
    let rawSHA256: String
    let presentationSHA256: String
    let dynamicIDCount: Int
}
