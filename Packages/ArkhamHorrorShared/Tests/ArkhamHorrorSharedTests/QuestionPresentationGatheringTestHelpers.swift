@testable import ArkhamHorrorShared

extension QuestionPresentation.Choice {
    func replacingSourceIndex(_ sourceIndex: Int) -> Self {
        Self(
            sourceIndex: sourceIndex,
            kind: kind,
            selectable: selectable,
            completesSelection: completesSelection,
            actorID: actorID,
            entity: entity,
            label: label,
            ability: ability,
            cost: cost,
            flippable: flippable,
            face: face,
            key: key,
            skillType: skillType,
            connection: connection,
            tarotCard: tarotCard,
            component: component,
            source: source,
            step: step,
            tooltip: tooltip,
            cards: cards,
            flavorText: flavorText,
            uiTag: uiTag,
            target: target,
            groupIndex: groupIndex
        )
    }

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

    func matchesGatheringHallwayMovement() -> Bool {
        kind == .move && ability?.cardCode == "c01112"
    }

    func matchesGatheringInvestigation(cardCode: String) -> Bool {
        kind == .investigate && ability?.cardCode == cardCode
    }
}
