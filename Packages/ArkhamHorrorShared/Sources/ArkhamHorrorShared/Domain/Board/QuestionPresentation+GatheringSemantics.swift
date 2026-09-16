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
            return governedChoices == [
                .gatheringCellarMove,
                .gatheringAtticMove,
            ]
        case (37, .windowChooseOne, 1):
            return choices == [.gatheringCellarForcedAbility]
                || choices == [.gatheringAtticForcedAbility]
        case (38, .chooseOne, 1):
            return choices == [.gatheringCellarDamageAssignment]
                || choices == [.gatheringAtticHorrorAssignment]
        default:
            return governedChoices.isEmpty
        }
    }
}

extension QuestionPresentation.Choice {
    static let gatheringCellarLocationID =
        "a3497b9f-796b-406d-aeb4-9b96fa9f4905"
    static let gatheringAtticLocationID =
        "dbaa2d2e-4ceb-44b2-a554-e5fa370e7882"

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

    static let gatheringCellarMove = Self(
        sourceIndex: 9,
        kind: .move,
        actorID: "c01001",
        entity: .init(
            kind: .location,
            id: gatheringCellarLocationID
        ),
        label: nil,
        ability: .init(
            cardCode: "c01114",
            index: 104,
            type: .action,
            actions: [.move],
            canBeCancelled: true
        ),
        cost: .all([.action(1), .other])
    )

    static let gatheringAtticMove = Self(
        sourceIndex: 10,
        kind: .move,
        actorID: "c01001",
        entity: .init(
            kind: .location,
            id: gatheringAtticLocationID
        ),
        label: nil,
        ability: .init(
            cardCode: "c01113",
            index: 104,
            type: .action,
            actions: [.move],
            canBeCancelled: true
        ),
        cost: .all([.action(1), .other])
    )

    static let gatheringCellarForcedAbility = Self(
        sourceIndex: 0,
        kind: .resolveForcedAbility,
        actorID: "c01001",
        entity: .init(
            kind: .location,
            id: gatheringCellarLocationID
        ),
        label: nil,
        ability: .init(
            cardCode: "c01114",
            index: 1,
            type: .forced,
            actions: [],
            canBeCancelled: true
        ),
        cost: .free
    )

    static let gatheringAtticForcedAbility = Self(
        sourceIndex: 0,
        kind: .resolveForcedAbility,
        actorID: "c01001",
        entity: .init(
            kind: .location,
            id: gatheringAtticLocationID
        ),
        label: nil,
        ability: .init(
            cardCode: "c01113",
            index: 1,
            type: .forced,
            actions: [],
            canBeCancelled: true
        ),
        cost: .free
    )

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
