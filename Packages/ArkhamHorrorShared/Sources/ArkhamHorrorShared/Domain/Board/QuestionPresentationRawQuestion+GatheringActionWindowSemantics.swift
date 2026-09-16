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

    // swiftlint:disable:next function_body_length
    private func validateGatheringAtticActionWindow(
        for presentation: QuestionPresentation
    ) throws -> Bool {
        let candidates = [
            GatheringAtticActionWindowRawRoles(
                atticMovement: 9,
                hallwayInvestigation: 10,
                cellarMovement: 11
            ),
            GatheringAtticActionWindowRawRoles(
                atticMovement: 9,
                hallwayInvestigation: 11,
                cellarMovement: 10
            ),
            GatheringAtticActionWindowRawRoles(
                atticMovement: 10,
                hallwayInvestigation: 9,
                cellarMovement: 11
            ),
            GatheringAtticActionWindowRawRoles(
                atticMovement: 10,
                hallwayInvestigation: 11,
                cellarMovement: 9
            ),
            GatheringAtticActionWindowRawRoles(
                atticMovement: 11,
                hallwayInvestigation: 9,
                cellarMovement: 10
            ),
            GatheringAtticActionWindowRawRoles(
                atticMovement: 11,
                hallwayInvestigation: 10,
                cellarMovement: 9
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
                "f5c36e8051a3375c37f1e63b5d0d7543f842fa0992797c20cc87468532b352c7"
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
            "f5c36e8051a3375c37f1e63b5d0d7543f842fa0992797c20cc87468532b352c7",
            presentationSeal.canonicalSHA256 ==
            "bb8b3bfc28f16b939b10d718c6e4dd00e6ef1912065a00f174509f1b41068266",
            rawSeal.dynamicIDs.count == 9,
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
        result[9] = choices[roles.atticMovement]
        result[10] = choices[roles.hallwayInvestigation]
        result[11] = choices[roles.cellarMovement]
        return result
    }

    private func canonicalPresentationChoices(
        _ choices: [QuestionPresentation.Choice],
        roles: GatheringAtticActionWindowRawRoles
    ) -> [QuestionPresentation.Choice] {
        var result = choices
        result[9] = choices[roles.atticMovement].replacingSourceIndex(9)
        result[10] =
            choices[roles.hallwayInvestigation].replacingSourceIndex(10)
        result[11] = choices[roles.cellarMovement].replacingSourceIndex(11)
        return result
    }
}

private struct GatheringAtticActionWindowRawRoles {
    let atticMovement: Int
    let hallwayInvestigation: Int
    let cellarMovement: Int
}
