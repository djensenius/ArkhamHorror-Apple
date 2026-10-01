extension BasicChoicePromptPresentation {
    func semanticEntityTitle(
        _ entity: QuestionPresentation.Entity,
        in projection: BoardProjection
    ) -> String? {
        switch entity.kind {
        case .act:
            guard let id = semanticActID(entity.id),
                  let act = projection.acts.first(where: { $0.id == id })
            else { return nil }
            return cardCatalog?.displayName(for: act.cardCode) ?? "Act \(act.sequence.step)"
        case .agenda:
            guard let id = semanticAgendaID(entity.id),
                  let agenda = projection.agendas.first(where: { $0.id == id })
            else { return nil }
            return cardCatalog?.displayName(for: agenda.cardCode)
                ?? "Agenda \(agenda.sequence.step)"
        case .asset:
            guard let id = semanticAssetID(entity.id) else { return nil }
            return projection.inPlayCardsByPlayer.values.flatMap(\.self).first {
                $0.id == .asset(id)
            }?.displayName
        case .card:
            guard let id = semanticWireCardID(entity.id) else { return nil }
            return projection.handCardsByPlayer[ownerID]?[id]?.displayLabel
                ?? projection.handCardsByPlayer.values.compactMap { $0[id]?.displayLabel }.first
        case .cardCode:
            guard let code = try? CardCode(entity.id) else { return nil }
            return cardCatalog?.displayName(for: code) ?? code.rawValue
        case .enemy:
            guard let id = semanticEnemyID(entity.id) else { return nil }
            return projection.enemiesByLocationID.values.flatMap(\.self).first { $0.id == id }?.displayName
                ?? projection.engagedEnemiesByInvestigatorID.values.flatMap(\.self).first { $0.id == id }?.displayName
        case .event:
            guard let id = semanticEventID(entity.id) else { return nil }
            return projection.inPlayCardsByPlayer.values.flatMap(\.self).first {
                $0.id == .event(id)
            }?.displayName
        case .investigator:
            guard let id = semanticInvestigatorID(entity.id) else { return nil }
            return projection.investigators.first(where: { $0.id == id })?.displayName
        case .location:
            guard let id = semanticLocationID(entity.id) else { return nil }
            return projection.locations.first(where: { $0.id == id })?.displayLabel
                ?? projection.enemyLocations.first(where: { $0.id == id })?.displayLabel
        case .player:
            guard let id = semanticPlayerID(entity.id) else { return nil }
            return projection.investigators.first(where: { $0.playerID == id })?.displayName
        case .scenario:
            return projection.scenario?.displayName
        case .skill:
            guard let id = semanticSkillID(entity.id) else { return nil }
            return projection.inPlayCardsByPlayer.values.flatMap(\.self).first {
                $0.id == .skill(id)
            }?.displayName
        case .treachery:
            guard let id = semanticTreacheryID(entity.id) else { return nil }
            return projection.threatTreacheriesByPlayer.values.flatMap(\.self).first {
                $0.id == id
            }?.displayName
        case .effect, .story:
            return nil
        }
    }

    // swiftlint:disable:next function_body_length
    func semanticUnavailableAnnouncement(
        for descriptor: QuestionPresentation.Choice,
        labelResolution: BasicChoiceLabelResolution?
    ) -> String {
        if descriptor.label != nil {
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
        case .drawCard, .drawEncounterCard, .endTurn, .gainResource, .skipTriggers,
             .startSkillTest, .useAbility:
            return semanticLocalized(
                "semantic.choice.unavailable.investigator",
                value:
                "The investigator for this choice is not currently available."
            )
        case .applySkillTestResults, .auto, .auxiliaryComponentLabel, .cardPile,
             .chaosTokenGroupChoice, .chaosTokenLabel, .componentLabel, .connectionLabel,
             .costLabel, .effectActionButton, .info, .invalidLabel, .keyLabel,
             .localizedLabel, .opaque, .skillLabel, .tarotLabel, .wizardChoice:
            return semanticLocalized(
                "semantic.choice.unavailable.generic",
                value: "This choice is not currently available."
            )
        }
    }

    private func semanticActID(_ raw: String) -> ActID? {
        guard let code = try? CardCode(raw) else { return nil }
        return ActID(code)
    }

    private func semanticAgendaID(_ raw: String) -> AgendaID? {
        guard let code = try? CardCode(raw) else { return nil }
        return AgendaID(code)
    }

    private func semanticAssetID(_ raw: String) -> AssetID? {
        AssetID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private func semanticEnemyID(_ raw: String) -> EnemyID? {
        EnemyID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private func semanticEventID(_ raw: String) -> EventID? {
        EventID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private func semanticLocationID(_ raw: String) -> LocationID? {
        LocationID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private func semanticPlayerID(_ raw: String) -> PlayerID? {
        PlayerID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private func semanticSkillID(_ raw: String) -> SkillID? {
        SkillID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private func semanticTreacheryID(_ raw: String) -> TreacheryID? {
        TreacheryID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private func semanticWireCardID(_ raw: String) -> WireCardID? {
        WireCardID(codingKey: AnyCodingKey(stringValue: raw))
    }

    private func semanticInvestigatorID(_ raw: String) -> InvestigatorID? {
        guard let code = try? CardCode(raw) else { return nil }
        return InvestigatorID(code)
    }
}
