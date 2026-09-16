extension QuestionPresentation {
    var hasSupportedGatheringSemantics: Bool {
        let encounterDrawChoices = choices.filter {
            $0.kind == .drawEncounterCard
        }
        if !encounterDrawChoices.isEmpty {
            return questionKind == .chooseOne
                && choiceCount == 1
                && choices.count == 1
        }

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
            let investigations = choices.filter {
                $0.matchesGatheringInvestigation(
                    cardCode: "c01114"
                ) || $0.matchesGatheringInvestigation(
                    cardCode: "c01113"
                )
            }
            let hallways = choices.filter {
                $0.matchesGatheringHallwayMovement()
            }
            guard choices.map(\.sourceIndex) == Array(0 ..< 11),
                  investigations.count == 1,
                  hallways.count == 1,
                  let investigation = investigations.first,
                  let hallway = hallways.first,
                  Set([
                      investigation.sourceIndex,
                      hallway.sourceIndex,
                  ]) == [9, 10]
            else { return false }
            return governedChoices == [hallway]
        case (42, .playerWindowChooseOne, 12):
            return governedChoices.isEmpty
                || gatheringAtticActionWindowSemantics != nil
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
            sourceIndex: sourceIndex,
            locationID: locationID.codingKey.stringValue
        )
    }

    func matchesGatheringInvestigation(cardCode: String) -> Bool {
        guard let locationID = entity?.canonicalLocationID else {
            return false
        }
        return self == .gatheringInvestigation(
            sourceIndex: sourceIndex,
            cardCode: cardCode,
            locationID: locationID.codingKey.stringValue
        )
    }

    static func gatheringLocationMovement(
        sourceIndex: Int,
        cardCode: String,
        locationID: String,
        cost: QuestionPresentation.Cost
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
            cost: cost
        )
    }

    static func gatheringMovement(
        sourceIndex: Int,
        cardCode: String,
        locationID: String
    ) -> Self {
        gatheringLocationMovement(
            sourceIndex: sourceIndex,
            cardCode: cardCode,
            locationID: locationID,
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

    static func gatheringHallwayMovement(
        sourceIndex: Int = 10,
        locationID: String
    ) -> Self {
        gatheringLocationMovement(
            sourceIndex: sourceIndex,
            cardCode: "c01112",
            locationID: locationID,
            cost: .action(1)
        )
    }

    static func gatheringInvestigation(
        sourceIndex: Int = 9,
        cardCode: String,
        locationID: String
    ) -> Self {
        Self(
            sourceIndex: sourceIndex,
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

    static func encounterDeckDraw(actorID: String) -> Self {
        Self(
            sourceIndex: 0,
            kind: .drawEncounterCard,
            actorID: actorID,
            entity: nil,
            label: nil,
            ability: nil,
            cost: nil
        )
    }
}

extension QuestionPresentation.Entity {
    var canonicalLocationID: LocationID? {
        guard kind == .location else { return nil }
        return LocationID(codingKey: AnyCodingKey(stringValue: id))
    }
}
