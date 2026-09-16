extension BasicChoicePromptPresentation {
    func semanticEntityTitle(
        _ entity: QuestionPresentation.Entity,
        in projection: BoardProjection
    ) -> String? {
        switch entity.kind {
        case .location:
            guard let id = semanticLocationID(entity.id) else { return nil }
            return projection.locations.first(where: { $0.id == id })?.displayLabel
                ?? projection.enemyLocations.first(where: { $0.id == id })?.displayLabel
        case .investigator:
            guard let id = semanticInvestigatorID(entity.id) else { return nil }
            return projection.investigators.first(where: { $0.id == id })?.displayName
        case .card:
            guard let id = semanticWireCardID(entity.id) else { return nil }
            return projection.handCardsByPlayer[ownerID]?[id]?.displayLabel
        case .scenario:
            return projection.scenario?.displayName
        case .act, .agenda, .asset, .cardCode, .effect, .enemy, .event, .player, .skill,
             .story, .treachery:
            return nil
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func semanticUnavailableAnnouncement(
        for descriptor: QuestionPresentation.Choice,
        labelResolution: BasicChoiceLabelResolution?
    ) -> String {
        if descriptor.kind == .localizedLabel {
            return labelResolution?.announcement
                ?? semanticLocalized(
                    "semantic.choice.unavailable.text",
                    value: "The text for this choice is not currently available."
                )
        }
        switch descriptor.kind {
        case .advanceAct:
            return semanticLocalized(
                "semantic.choice.unavailable.advanceAct",
                value:
                "The act or investigator for this choice is not currently available."
            )
        case .advanceAgenda:
            return semanticLocalized(
                "semantic.choice.unavailable.advanceAgenda",
                value:
                "The agenda or investigator for this choice is not currently available."
            )
        case .fight, .evade, .engage:
            return semanticLocalized(
                "semantic.choice.unavailable.enemy",
                value:
                "The enemy or investigator for this choice is not currently available."
            )
        case .investigate, .move:
            return semanticLocalized(
                "semantic.choice.unavailable.location",
                value:
                "The location or investigator for this choice is not currently available."
            )
        case .resolveForcedAbility:
            return semanticLocalized(
                "semantic.choice.unavailable.forcedAbility",
                value:
                "The source or investigator for this forced ability is not currently available."
            )
        case .chooseTarget:
            return semanticLocalized(
                "semantic.choice.unavailable.target",
                value: "The target for this choice is not currently available."
            )
        case .assignDamage, .assignHorror:
            return semanticLocalized(
                "semantic.choice.unavailable.assignment",
                value:
                "The investigator for this assignment is not currently available."
            )
        case .drawCard, .endTurn, .gainResource, .skipTriggers, .startSkillTest, .useAbility:
            return semanticLocalized(
                "semantic.choice.unavailable.investigator",
                value:
                "The investigator for this choice is not currently available."
            )
        case .applySkillTestResults:
            return semanticLocalized(
                "semantic.choice.unavailable.generic",
                value: "This choice is not currently available."
            )
        case .localizedLabel:
            return semanticLocalized(
                "semantic.choice.unavailable.text",
                value: "The text for this choice is not currently available."
            )
        }
    }

    private func semanticLocationID(_ raw: String) -> LocationID? {
        LocationID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private func semanticWireCardID(_ raw: String) -> WireCardID? {
        WireCardID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private func semanticInvestigatorID(_ raw: String) -> InvestigatorID? {
        guard let code = try? CardCode(raw) else { return nil }
        return InvestigatorID(code)
    }
}
