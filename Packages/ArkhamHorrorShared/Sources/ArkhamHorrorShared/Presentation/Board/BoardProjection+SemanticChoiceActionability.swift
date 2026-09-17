extension BoardProjection {
    // swiftlint:disable:next cyclomatic_complexity
    func isSemanticChoiceActionable(
        _ choice: QuestionPresentation.Choice,
        ownerID: PlayerID,
        labelResolution: BasicChoiceLabelResolution?,
        governedSource: QuestionPresentation.GovernedSource? = nil
    ) -> Bool {
        guard containsSemanticChoiceIdentities(choice, ownerID: ownerID) else { return false }
        switch choice.kind {
        case .advanceAct:
            return choice.entity?.kind == .act
        case .advanceAgenda:
            return choice.entity?.kind == .agenda
        case .applySkillTestResults:
            return true
        case .assignDamage, .assignHorror:
            return choice.entity?.kind == .investigator
                && choice.actorID == nil && choice.ability == nil && choice.cost == nil
                && containsGovernedSource(governedSource, ownerID: ownerID)
        case .chooseTarget:
            return choice.entity != nil
        case .drawCard, .drawEncounterCard, .endTurn, .gainResource, .skipTriggers,
             .startSkillTest:
            return choice.actorID != nil
        case .engage, .evade, .fight:
            return choice.entity?.kind == .enemy
        case .investigate:
            return choice.entity?.kind == .location
                && semanticLocation(
                    choice.entity,
                    hasCardCode: choice.ability?.cardCode
                )
        case .localizedLabel:
            return labelResolution?.isResolved == true
        case .move:
            return choice.entity?.kind == .location
                && choice.actorID != nil && choice.ability != nil && choice.cost != nil
                && semanticLocation(
                    choice.entity,
                    hasCardCode: choice.ability?.cardCode
                )
        case .resolveForcedAbility:
            return choice.entity?.kind == .location
                && choice.actorID != nil && choice.ability != nil && choice.cost != nil
                && semanticLocation(
                    choice.entity,
                    hasCardCode: choice.ability?.cardCode
                )
        case .useAbility:
            return choice.actorID != nil && choice.ability != nil && choice.cost != nil
        }
    }

    private func containsGovernedSource(
        _ source: QuestionPresentation.GovernedSource?,
        ownerID: PlayerID
    ) -> Bool {
        guard let source else { return true }
        return containsSemanticEntity(source.entity, ownerID: ownerID)
            && semanticLocation(source.entity, hasCardCode: source.cardCode)
    }

    private func semanticLocation(
        _ entity: QuestionPresentation.Entity?,
        hasCardCode rawCardCode: String?
    ) -> Bool {
        guard let locationID = entity?.canonicalLocationID,
              let rawCardCode,
              let cardCode = try? CardCode(rawCardCode)
        else { return false }
        return locations.contains {
            $0.id == locationID && $0.cardCode == cardCode
        } || enemyLocations.contains {
            $0.id == locationID && $0.cardCode == cardCode
        }
    }

    private func containsSemanticChoiceIdentities(
        _ choice: QuestionPresentation.Choice,
        ownerID: PlayerID
    ) -> Bool {
        if let actorID = choice.actorID, !containsInvestigator(actorID) {
            return false
        }
        if let entity = choice.entity, !containsSemanticEntity(entity, ownerID: ownerID) {
            return false
        }
        return true
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func containsSemanticEntity(
        _ entity: QuestionPresentation.Entity,
        ownerID: PlayerID
    ) -> Bool {
        switch entity.kind {
        case .act:
            guard let id = cardCodeIdentifier(entity.id, as: ActID.self) else { return false }
            return acts.contains { $0.id == id }
        case .agenda:
            guard let id = cardCodeIdentifier(entity.id, as: AgendaID.self) else { return false }
            return agendas.contains { $0.id == id }
        case .card:
            guard let id = uuidIdentifier(entity.id, as: WireCardID.self) else { return false }
            return handCardsByPlayer[ownerID]?[id] != nil
        case .enemy:
            guard let id = uuidIdentifier(entity.id, as: EnemyID.self) else { return false }
            return enemyIDs.contains(id)
        case .investigator:
            return containsInvestigator(entity.id)
        case .location:
            guard let id = uuidIdentifier(entity.id, as: LocationID.self) else { return false }
            return locations.contains { $0.id == id }
                || enemyLocations.contains { $0.id == id }
        case .player:
            guard let id = uuidIdentifier(entity.id, as: PlayerID.self) else { return false }
            return id == ownerID || handCardsByPlayer[id] != nil
        case .scenario:
            return projectionHasScenario(entity.id)
        case .treachery:
            guard let id = uuidIdentifier(entity.id, as: TreacheryID.self) else { return false }
            return treacheryIDs.contains(id)
        case .asset, .cardCode, .effect, .event, .skill, .story:
            return false
        }
    }

    private func containsInvestigator(_ rawID: String) -> Bool {
        guard let code = try? CardCode(rawID) else { return false }
        let id = InvestigatorID(code)
        return investigators.contains { $0.id == id }
    }

    private func projectionHasScenario(_ rawID: String) -> Bool {
        guard scenario != nil else { return false }
        return rawID == "scenario"
    }

    private func cardCodeIdentifier<Tag: Sendable>(
        _ raw: String,
        as _: CardCodeIdentifier<Tag>.Type
    ) -> CardCodeIdentifier<Tag>? {
        guard let code = try? CardCode(raw) else { return nil }
        return CardCodeIdentifier(code)
    }

    private func uuidIdentifier<Tag: Sendable>(
        _ raw: String,
        as _: Identifier<Tag>.Type
    ) -> Identifier<Tag>? {
        Identifier(codingKey: AnyCodingKey(stringValue: raw))
    }
}
