extension QuestionPresentation {
    var hasSupportedGatheringSemantics: Bool {
        let governedKinds: Set<ChoiceKind> = [
            .advanceAct,
            .assignDamage,
            .assignHorror,
            .move,
            .resolveForcedAbility,
        ]
        let governedChoices = choices.filter { governedKinds.contains($0.kind) }
        switch (questionVersion, questionKind, choiceCount) {
        case (34, .playerWindowChooseOne, 13):
            return governedChoices == [.gatheringActObjective]
        case (35, .chooseOne, 1):
            return choices == [.gatheringActAdvance]
        case (36, .playerWindowChooseOne, 12):
            guard choices.map(\.sourceIndex) == Array(0 ..< 12),
                  let cellar = choices.first(where: { $0.sourceIndex == 9 }),
                  let attic = choices.first(where: { $0.sourceIndex == 10 }),
                  cellar.matchesGatheringMovement(
                      sourceIndex: 9,
                      cardCode: "c01114"
                  ),
                  attic.matchesGatheringMovement(
                      sourceIndex: 10,
                      cardCode: "c01113"
                  )
            else { return false }
            return governedChoices.map(\.sourceIndex) == [9, 10]
        case (37, .windowChooseOne, 1):
            guard let choice = choices.first else { return false }
            return choice.matchesGatheringForcedAbility(cardCode: "c01114")
                || choice.matchesGatheringForcedAbility(cardCode: "c01113")
        case (38, .chooseOne, 1):
            return choices == [.gatheringCellarDamageAssignment]
                || choices == [.gatheringAtticHorrorAssignment]
        case (39, .playerWindowChooseOne, 11):
            guard choices.map(\.sourceIndex) == Array(0 ..< 11),
                  let investigation = choices.first(
                      where: { $0.sourceIndex == 9 }
                  ),
                  let hallway = choices.first(where: { $0.sourceIndex == 10 }),
                  investigation.matchesGatheringInvestigation(
                      cardCode: "c01114"
                  ) || investigation.matchesGatheringInvestigation(
                      cardCode: "c01113"
                  ),
                  hallway.matchesGatheringHallwayMovement()
            else { return false }
            return governedChoices.map(\.sourceIndex) == [10]
        default:
            return governedChoices.isEmpty
        }
    }
}

extension QuestionPresentation.Choice {
    static let gatheringActObjective = Self(
        sourceIndex: 12,
        kind: .advanceAct,
        actorID: "c01001",
        entity: .init(kind: .act, id: "c01108"),
        label: nil,
        ability: .init(
            cardCode: "c01108",
            index: 999,
            type: .objective,
            actions: [],
            canBeCancelled: true
        ),
        cost: .groupClue(amount: .perPlayer(2), scope: .anywhere)
    )

    static let gatheringActAdvance = Self(
        sourceIndex: 0,
        kind: .advanceAct,
        actorID: nil,
        entity: .init(kind: .act, id: "c01108"),
        label: nil,
        ability: nil,
        cost: nil
    )

    func matchesGatheringMovement(
        sourceIndex: Int,
        cardCode: String
    ) -> Bool {
        guard let locationID = entity?.canonicalLocationID else {
            return false
        }
        return self == .gatheringMovement(
            sourceIndex: sourceIndex,
            cardCode: cardCode,
            locationID: locationID.codingKey.stringValue
        )
    }

    func matchesGatheringForcedAbility(cardCode: String) -> Bool {
        guard let locationID = entity?.canonicalLocationID else {
            return false
        }
        return self == .gatheringForcedAbility(
            cardCode: cardCode,
            locationID: locationID.codingKey.stringValue
        )
    }

    func matchesGatheringHallwayMovement() -> Bool {
        guard let locationID = entity?.canonicalLocationID else {
            return false
        }
        return self == .gatheringHallwayMovement(
            locationID: locationID.codingKey.stringValue
        )
    }

    func matchesGatheringInvestigation(cardCode: String) -> Bool {
        guard let locationID = entity?.canonicalLocationID else {
            return false
        }
        return self == .gatheringInvestigation(
            cardCode: cardCode,
            locationID: locationID.codingKey.stringValue
        )
    }

    static func gatheringMovement(
        sourceIndex: Int,
        cardCode: String,
        locationID: String
    ) -> Self {
        Self(
            sourceIndex: sourceIndex,
            kind: .move,
            actorID: "c01001",
            entity: .init(kind: .location, id: locationID),
            label: nil,
            ability: .init(
                cardCode: cardCode,
                index: 104,
                type: .action,
                actions: [.move],
                canBeCancelled: true
            ),
            cost: .all([.action(1), .other])
        )
    }

    static func gatheringForcedAbility(
        cardCode: String,
        locationID: String
    ) -> Self {
        Self(
            sourceIndex: 0,
            kind: .resolveForcedAbility,
            actorID: "c01001",
            entity: .init(kind: .location, id: locationID),
            label: nil,
            ability: .init(
                cardCode: cardCode,
                index: 1,
                type: .forced,
                actions: [],
                canBeCancelled: true
            ),
            cost: .free
        )
    }

    static func gatheringHallwayMovement(locationID: String) -> Self {
        Self(
            sourceIndex: 10,
            kind: .move,
            actorID: "c01001",
            entity: .init(kind: .location, id: locationID),
            label: nil,
            ability: .init(
                cardCode: "c01112",
                index: 104,
                type: .action,
                actions: [.move],
                canBeCancelled: true
            ),
            cost: .action(1)
        )
    }

    static func gatheringInvestigation(
        cardCode: String,
        locationID: String
    ) -> Self {
        Self(
            sourceIndex: 9,
            kind: .investigate,
            actorID: "c01001",
            entity: .init(kind: .location, id: locationID),
            label: nil,
            ability: .init(
                cardCode: cardCode,
                index: 103,
                type: .action,
                actions: [.investigate],
                canBeCancelled: true
            ),
            cost: .action(1)
        )
    }

    static let gatheringCellarDamageAssignment = Self(
        sourceIndex: 0,
        kind: .assignDamage,
        actorID: nil,
        entity: .init(kind: .investigator, id: "c01001"),
        label: nil,
        ability: nil,
        cost: nil
    )

    static let gatheringAtticHorrorAssignment = Self(
        sourceIndex: 0,
        kind: .assignHorror,
        actorID: nil,
        entity: .init(kind: .investigator, id: "c01001"),
        label: nil,
        ability: nil,
        cost: nil
    )
}

extension QuestionPresentation.Entity {
    var canonicalLocationID: LocationID? {
        guard kind == .location else { return nil }
        return LocationID(codingKey: AnyCodingKey(stringValue: id))
    }
}
