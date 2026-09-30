// swiftlint:disable file_length identifier_name
enum QuestionPresentationSealValidationKind: Sendable, Equatable {
    case encounterDraw
    case treacheryForcedAbility
    case gatheringActObjective
    case gatheringActAdvance
    case gatheringMovement
    case gatheringLocationForcedAbility
    case gatheringAssignment
    case gatheringPostEntry
    case gatheringStartSkillTest
    case gatheringEndTurn
    case gatheringApplySkillTestResults
    case gatheringAtticActionWindow

    var allowsGenericFallbackOnFailure: Bool {
        self != .treacheryForcedAbility
    }
}

extension QuestionPresentation {
    var sealValidationKind: QuestionPresentationSealValidationKind? {
        if isEncounterDrawSealCandidate {
            return .encounterDraw
        }
        if isTreacheryForcedAbilitySealCandidate {
            return .treacheryForcedAbility
        }
        if isGatheringAtticActionWindowSealCandidate {
            return .gatheringAtticActionWindow
        }
        if isGatheringActObjectiveSealCandidate {
            return .gatheringActObjective
        }
        if isGatheringActAdvanceSealCandidate {
            return .gatheringActAdvance
        }
        if isGatheringMovementSealCandidate {
            return .gatheringMovement
        }
        if isGatheringLocationForcedAbilitySealCandidate {
            return .gatheringLocationForcedAbility
        }
        if isGatheringAssignmentSealCandidate {
            return .gatheringAssignment
        }
        if isGatheringPostEntrySealCandidate {
            return .gatheringPostEntry
        }
        if isGatheringStartSkillTestSealCandidate {
            return .gatheringStartSkillTest
        }
        if isGatheringEndTurnSealCandidate {
            return .gatheringEndTurn
        }
        if isGatheringApplySkillTestResultsSealCandidate {
            return .gatheringApplySkillTestResults
        }
        return nil
    }

    var hasSupportedSealedActionabilityOverlay: Bool {
        switch sealValidationKind {
        case .encounterDraw:
            return questionKind == .chooseOne
                && choiceCount == 1
                && choices.count == 1
                && choices[0].kind == .drawEncounterCard
        case .treacheryForcedAbility:
            return questionKind == .windowChooseOne
                && governedChoices == treacheryForcedChoices
        case .gatheringActObjective:
            return questionVersion == 34
                && questionKind == .playerWindowChooseOne
                && choiceCount == 13
                && governedChoices == [.gatheringActObjective]
        case .gatheringActAdvance:
            return questionVersion == 35
                && questionKind == .chooseOne
                && choiceCount == 1
                && choices == [.gatheringActAdvance]
        case .gatheringMovement:
            guard questionVersion == 36,
                  questionKind == .playerWindowChooseOne,
                  choiceCount == 12,
                  choices.map(\.sourceIndex) == Array(0 ..< 12),
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
        case .gatheringLocationForcedAbility:
            guard questionVersion == 37,
                  questionKind == .windowChooseOne,
                  choiceCount == 1,
                  let choice = choices.first
            else { return false }
            return choice.matchesGatheringForcedAbility(cardCode: "c01114")
                || choice.matchesGatheringForcedAbility(cardCode: "c01113")
        case .gatheringAssignment:
            return questionVersion == 38
                && questionKind == .chooseOne
                && choiceCount == 1
                && (choices == [.gatheringCellarDamageAssignment]
                    || choices == [.gatheringAtticHorrorAssignment])
        case .gatheringPostEntry:
            guard questionVersion == 39 else { return false }
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
            guard questionKind == .playerWindowChooseOne,
                  choiceCount == 11,
                  choices.map(\.sourceIndex) == Array(0 ..< 11),
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
        case .gatheringStartSkillTest:
            return questionVersion == 40
                && questionKind == .chooseOne
                && choiceCount == 1
                && choices == [.gatheringStartSkillTest]
        case .gatheringEndTurn:
            return (questionVersion == 40 || questionVersion == 42)
                && questionKind == .playerWindowChooseOne
                && choiceCount == 1
                && choices == [.gatheringEndTurn(sourceIndex: 0)]
        case .gatheringApplySkillTestResults:
            return questionVersion == 41
                && questionKind == .chooseOne
                && choiceCount == 1
                && choices == [.gatheringApplySkillTestResults]
        case .gatheringAtticActionWindow:
            return questionVersion == 42
                && questionKind == .playerWindowChooseOne
                && (choiceCount == 12 || choiceCount == 13)
                && gatheringAtticActionWindowSemantics != nil
        case nil:
            return false
        }
    }

    var hasSupportedGatheringSemantics: Bool {
        guard let kind = sealValidationKind,
              kind != .encounterDraw,
              kind != .treacheryForcedAbility
        else { return false }
        return hasSupportedSealedActionabilityOverlay
    }

    var allowsGenericFallbackOnSealFailure: Bool {
        sealValidationKind?.allowsGenericFallbackOnFailure == true
    }

    private var isEncounterDrawSealCandidate: Bool {
        questionKind == .chooseOne
            && choiceCount == 1
            && choices.count == 1
            && choices[0].kind == .drawEncounterCard
    }

    private var isTreacheryForcedAbilitySealCandidate: Bool {
        questionKind == .windowChooseOne
            && !treacheryForcedChoices.isEmpty
            && governedChoices == treacheryForcedChoices
    }

    private var isGatheringActObjectiveSealCandidate: Bool {
        questionKind == .playerWindowChooseOne
            && choiceCount == 13
            && choices.contains {
                $0.sourceIndex == 12 && $0.kind == .advanceAct
            }
    }

    private var isGatheringActAdvanceSealCandidate: Bool {
        questionKind == .chooseOne
            && choiceCount == 1
            && choices.first?.kind == .advanceAct
    }

    private var isGatheringMovementSealCandidate: Bool {
        questionKind == .playerWindowChooseOne
            && choiceCount == 12
            && choices.contains {
                $0.kind == .move
                    && ($0.sourceIndex == 9 || $0.sourceIndex == 10)
            }
    }

    private var isGatheringLocationForcedAbilitySealCandidate: Bool {
        questionKind == .windowChooseOne
            && choiceCount == 1
            && choices.first?.kind == .resolveForcedAbility
            && choices.first?.entity?.kind == .location
    }

    private var isGatheringAssignmentSealCandidate: Bool {
        questionKind == .chooseOne
            && choiceCount == 1
            && choices.contains {
                $0.kind == .assignDamage || $0.kind == .assignHorror
            }
    }

    private var isGatheringPostEntrySealCandidate: Bool {
        questionKind == .playerWindowChooseOne
            && choiceCount == 11
            && choices.contains { $0.kind == .move }
            && choices.contains { $0.kind == .investigate }
    }

    private var isGatheringStartSkillTestSealCandidate: Bool {
        questionKind == .chooseOne
            && choiceCount == 1
            && choices.first?.kind == .startSkillTest
    }

    private var isGatheringEndTurnSealCandidate: Bool {
        questionKind == .playerWindowChooseOne
            && choiceCount == 1
            && choices.first?.kind == .endTurn
    }

    private var isGatheringApplySkillTestResultsSealCandidate: Bool {
        questionKind == .chooseOne
            && choiceCount == 1
            && choices.first?.kind == .applySkillTestResults
    }

    private var isGatheringAtticActionWindowSealCandidate: Bool {
        questionKind == .playerWindowChooseOne
            && (choiceCount == 12 || choiceCount == 13)
            && gatheringAtticActionWindowSemantics != nil
    }

    private var governedChoices: [Choice] {
        let governedKinds: Set<ChoiceKind> = [
            .advanceAct,
            .assignDamage,
            .assignHorror,
            .move,
            .resolveForcedAbility,
        ]
        return choices.filter { governedKinds.contains($0.kind) }
    }

    private var treacheryForcedChoices: [Choice] {
        governedChoices.filter {
            $0.kind == .resolveForcedAbility
                && $0.entity?.kind == .treachery
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

// swiftlint:enable file_length identifier_name
