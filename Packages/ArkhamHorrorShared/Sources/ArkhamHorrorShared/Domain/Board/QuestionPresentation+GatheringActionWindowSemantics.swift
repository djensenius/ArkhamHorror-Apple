extension QuestionPresentation {
    var gatheringAtticActionWindowSemantics: GatheringAtticActionWindowSemantics? {
        guard choiceCount == choices.count,
              [12, 13].contains(choices.count),
              choices.map(\.sourceIndex) == Array(choices.indices),
              choices[0] == .gatheringGainResource,
              choices[1] == .gatheringDrawCard
        else { return nil }
        let endTurnSourceIndex = choices.count - 4
        let handCardSourceIndices = 2 ..< endTurnSourceIndex
        guard handCardSourceIndices.allSatisfy({
            choices[$0].matchesGatheringCardTarget(sourceIndex: $0)
        }),
            choices[endTurnSourceIndex] ==
            .gatheringEndTurn(sourceIndex: endTurnSourceIndex)
        else { return nil }
        let atticMovements = choices.filter {
            $0.matchesGatheringLocationMovement(
                cardCode: "c01113",
                cost: .action(1)
            )
        }
        let hallwayInvestigations = choices.filter {
            $0.matchesGatheringInvestigation(cardCode: "c01112")
        }
        let cellarMovements = choices.filter {
            $0.matchesGatheringLocationMovement(
                cardCode: "c01114",
                cost: .all([.action(1), .other])
            )
        }
        guard atticMovements.count == 1,
              hallwayInvestigations.count == 1,
              cellarMovements.count == 1,
              let atticMovement = atticMovements.first,
              let hallwayInvestigation = hallwayInvestigations.first,
              let cellarMovement = cellarMovements.first,
              Set([
                  atticMovement.sourceIndex,
                  hallwayInvestigation.sourceIndex,
                  cellarMovement.sourceIndex,
              ]) == Set((endTurnSourceIndex + 1) ..< choices.count)
        else { return nil }
        return GatheringAtticActionWindowSemantics(
            atticMovement: atticMovement,
            hallwayInvestigation: hallwayInvestigation,
            cellarMovement: cellarMovement
        )
    }
}

struct GatheringAtticActionWindowSemantics: Sendable, Equatable {
    let atticMovement: QuestionPresentation.Choice
    let hallwayInvestigation: QuestionPresentation.Choice
    let cellarMovement: QuestionPresentation.Choice
}

extension QuestionPresentation.Choice {
    static let gatheringGainResource = Self(
        sourceIndex: 0,
        kind: .gainResource,
        actorID: "c01001",
        entity: nil,
        label: nil,
        ability: nil,
        cost: nil
    )

    static let gatheringDrawCard = Self(
        sourceIndex: 1,
        kind: .drawCard,
        actorID: "c01001",
        entity: nil,
        label: nil,
        ability: nil,
        cost: nil
    )

    static let gatheringStartSkillTest = Self(
        sourceIndex: 0,
        kind: .startSkillTest,
        actorID: "c01001",
        entity: nil,
        label: nil,
        ability: nil,
        cost: nil
    )

    static let gatheringApplySkillTestResults = Self(
        sourceIndex: 0,
        kind: .applySkillTestResults,
        actorID: nil,
        entity: nil,
        label: nil,
        ability: nil,
        cost: nil
    )

    static func gatheringEndTurn(sourceIndex: Int) -> Self {
        Self(
            sourceIndex: sourceIndex,
            kind: .endTurn,
            actorID: "c01001",
            entity: nil,
            label: nil,
            ability: nil,
            cost: nil
        )
    }

    func matchesGatheringCardTarget(sourceIndex: Int) -> Bool {
        guard let cardID = entity?.canonicalCardID else {
            return false
        }
        return self == .gatheringCardTarget(
            sourceIndex: sourceIndex,
            cardID: cardID.codingKey.stringValue
        )
    }

    static func gatheringCardTarget(
        sourceIndex: Int,
        cardID: String
    ) -> Self {
        Self(
            sourceIndex: sourceIndex,
            kind: .chooseTarget,
            actorID: nil,
            entity: .init(kind: .card, id: cardID),
            label: nil,
            ability: nil,
            cost: nil
        )
    }

    func matchesGatheringLocationMovement(
        cardCode: String,
        cost: QuestionPresentation.Cost
    ) -> Bool {
        guard let locationID = entity?.canonicalLocationID else {
            return false
        }
        return self == .gatheringLocationMovement(
            sourceIndex: sourceIndex,
            cardCode: cardCode,
            locationID: locationID.codingKey.stringValue,
            cost: cost
        )
    }
}

private extension QuestionPresentation.Entity {
    var canonicalCardID: WireCardID? {
        guard kind == .card else { return nil }
        return WireCardID(codingKey: AnyCodingKey(stringValue: id))
    }
}
