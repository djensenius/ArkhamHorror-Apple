extension BoardProjection {
    /// Whether `choice` can actually be claimed/answered right now against this
    /// authoritative projection.
    ///
    /// This is deliberately a presentation/action-authority concern, distinct from
    /// ``BasicChoice/isSupported`` (which only reflects whether the wire shape itself
    /// parsed as a known, well-formed constructor):
    /// - A `.chooseLocation` choice can parse as fully supported yet still reference a
    ///   `LocationTarget` this projection doesn't (yet, or no longer) carry -- for example
    ///   if the prompt arrives before that location's own reveal is reflected in the
    ///   snapshot, or a later snapshot stops carrying it.
    /// - A `.continueReading` choice can parse as fully supported yet still belong to a
    ///   `Read` question whose flavor text this client cannot lawfully resolve into
    ///   human-readable narrative (see ``StoryNarrativeLocalization``) -- `story` must be
    ///   supplied by the caller (from the same question the choice belongs to) whenever
    ///   the choice being checked might be a `.continueReading` choice; omitting it makes
    ///   any such choice fail closed rather than silently defaulting to actionable.
    /// - A `.fight`, `.evade`, or `.engage` choice remains actionable only while its
    ///   authoritative `EnemySource` identity is still present in this projection.
    /// - Roland's post-defeat reaction remains actionable only while Roland and his
    ///   current location remain present; the defeated enemy is expected to be gone.
    /// - Cover Up's replacement reaction additionally requires the exact source treachery
    ///   to remain present with at least one authoritative clue token.
    ///
    /// Such a choice stays visible at its exact original index (never filtered/reindexed)
    /// but cannot be actioned until it is authoritatively resolvable. Recomputed fresh
    /// from the current projection (and, for `.continueReading`, the current question's
    /// story) on every call -- never cached or baked into the wire parser, which stays
    /// entirely projection-agnostic -- so a stale rendered choice is always revalidated
    /// immediately before it could be claimed or sent.
    func isChoiceActionable(
        _ choice: BasicChoice,
        ownerID: PlayerID? = nil,
        storyResolution: StoryResolution?,
        labelResolution: BasicChoiceLabelResolution? = nil
    ) -> Bool {
        guard choice.isSupported else { return false }
        switch choice.content {
        case .continueReading:
            return storyResolution?.isResolved == true
        case .finishMulligan:
            return labelResolution?.isResolved == true
        case .rolandDefeatReaction, .coverUpReaction, .resolveForcedAbility, .advanceAgenda,
             .chooseAgendaConsequence,
             .assignAgendaHorror:
            return isRoundChoiceActionable(choice.content, labelResolution: labelResolution)
        case let .chooseLocation(locationID, _):
            return locations.contains { $0.id == locationID }
        case let .chooseHandCard(cardID, _, _):
            guard let ownerID else { return false }
            return handCardsByPlayer[ownerID]?[cardID] != nil
        case .resolveEnemyAttack, .assignEnemyAttackDamage, .fight, .evade, .engage:
            return isEnemyChoiceActionable(choice.content)
        case .gainResource, .drawCard, .endTurn, .investigate, .skipTriggers,
             .startSkillTest, .applySkillTestResults, .drawEncounterCard:
            return true
        case .unsupported:
            return false
        }
    }

    private func isRoundChoiceActionable(
        _ content: BasicChoiceContent, labelResolution: BasicChoiceLabelResolution?
    ) -> Bool {
        switch content {
        case let .rolandDefeatReaction(reaction):
            isRolandDefeatReactionActionable(reaction)
        case let .coverUpReaction(reaction):
            isCoverUpReactionActionable(reaction)
        case let .resolveForcedAbility(forced):
            treacheryIDs.contains(forced.treacheryID)
                && investigators.contains { $0.id == forced.ability.investigatorID }
        case let .advanceAgenda(agendaID, _):
            agendas.contains { $0.id == agendaID }
        case let .chooseAgendaConsequence(consequence):
            labelResolution?.isResolved == true
                && agendas.contains { $0.id == consequence.agendaID }
                && consequence.investigatorID.map { investigatorID in
                    investigators.contains { $0.id == investigatorID }
                } != false
        case let .assignAgendaHorror(assignment):
            agendas.contains { $0.id == assignment.agendaID }
                && investigators.contains { $0.id == assignment.investigatorID }
        default:
            false
        }
    }

    private func isRolandDefeatReactionActionable(
        _ reaction: RolandDefeatReactionChoice
    ) -> Bool {
        guard let investigator = investigators.first(
            where: { $0.id == reaction.ability.investigatorID }
        ), let locationID = investigator.currentLocationID
        else { return false }
        return locations.contains { $0.id == locationID }
            || enemyLocations.contains { $0.id == locationID }
    }

    private func isCoverUpReactionActionable(
        _ reaction: CoverUpReactionChoice
    ) -> Bool {
        guard let investigator = investigators.first(
            where: { $0.id == reaction.ability.investigatorID }
        ), investigator.currentLocationID == reaction.locationID,
        locations.contains(where: { $0.id == reaction.locationID })
        || enemyLocations.contains(where: { $0.id == reaction.locationID }),
        let treachery = treacheriesByID[reaction.treacheryID]
        else { return false }
        return treachery.cardCode == reaction.ability.cardCode
            && treachery.clueCount > 0
    }

    private func isEnemyChoiceActionable(_ content: BasicChoiceContent) -> Bool {
        switch content {
        case let .resolveEnemyAttack(enemyID, investigatorID, _):
            enemyIDs.contains(enemyID)
                && investigators.contains { $0.id == investigatorID }
        case let .assignEnemyAttackDamage(assignment):
            enemyIDs.contains(assignment.enemyID)
                && investigators.contains { $0.id == assignment.investigatorID }
        case let .fight(_, enemyID), let .evade(_, enemyID), let .engage(_, enemyID):
            enemyIDs.contains(enemyID)
        default:
            false
        }
    }

    /// Compatibility overload for projection-only callers. Production prompt surfaces must
    /// pass their captured `StoryResolution` instead so they cannot separately resolve text.
    func isChoiceActionable(_ choice: BasicChoice, story: ReadStoryContent? = nil) -> Bool {
        let resolution = story.map {
            StoryNarrativeLocalization.resolve(
                $0.flavorText,
                resolver: nil,
                catalogUnavailability: .catalog(.notAdvertised)
            )
        }
        return isChoiceActionable(choice, storyResolution: resolution)
    }
}
