/// `CardDef`'s encode-side of `Codable` conformance. Split out of
/// `CardDefCodable.swift` (which holds the decode side, `CodingKeys`, and the
/// `DecodedPart1`-`DecodedPart4` types) purely to stay under SwiftLint's
/// file-length limit.
extension CardDef {
    private static func encodePart1(
        _ value: CardDef,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode(value.cardCode, forKey: .cardCode)
        try container.encode(value.name, forKey: .name)
        try container.encodeIfPresent(value.revealedName, forKey: .revealedName)
        try container.encodeIfPresent(value.cost, forKey: .cost)
        try value.additionalCost.encode(to: &container, forKey: .additionalCost)
        try container.encodeIfPresent(value.level, forKey: .level)
        try container.encode(value.cardType, forKey: .cardType)
        try container.encodeIfPresent(value.cardSubType, forKey: .cardSubType)
        try container.encodeIfPresent(value.classSymbols, forKey: .classSymbols)
        try container.encodeIfPresent(value.skills, forKey: .skills)
        try container.encodeIfPresent(value.cardTraits, forKey: .cardTraits)
        try container.encodeIfPresent(value.revealedCardTraits, forKey: .revealedCardTraits)
        try container.encodeIfPresent(value.keywords, forKey: .keywords)
        try value.fastWindow.encode(to: &container, forKey: .fastWindow)
        try value.actions.encode(to: &container, forKey: .actions)
        try container.encodeIfPresent(value.revelation, forKey: .revelation)
    }

    private static func encodePart2(
        _ value: CardDef,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encodeIfPresent(value.victoryPoints, forKey: .victoryPoints)
        try container.encodeIfPresent(value.vengeancePoints, forKey: .vengeancePoints)
        try value.criteria.encode(to: &container, forKey: .criteria)
        try container.encodeIfPresent(
            value.overrideActionPlayableIfCriteriaMet,
            forKey: .overrideActionPlayableIfCriteriaMet
        )
        try container.encodeIfPresent(value.commitRestrictions, forKey: .commitRestrictions)
        try container.encodeIfPresent(
            value.attackOfOpportunityModifiers,
            forKey: .attackOfOpportunityModifiers
        )
        try container.encodeIfPresent(value.permanent, forKey: .permanent)
        try container.encodeIfPresent(value.encounterSet, forKey: .encounterSet)
        try container.encodeIfPresent(value.encounterSetQuantity, forKey: .encounterSetQuantity)
        try container.encodeIfPresent(value.unique, forKey: .unique)
        try container.encodeIfPresent(value.doubleSided, forKey: .doubleSided)
        try container.encodeIfPresent(value.limits, forKey: .limits)
        try container.encodeIfPresent(value.exceptional, forKey: .exceptional)
        try value.uses.encode(to: &container, forKey: .uses)
        try container.encodeIfPresent(value.playableFromDiscard, forKey: .playableFromDiscard)
        try container.encodeIfPresent(value.stage, forKey: .stage)
    }

    private static func encodePart3(
        _ value: CardDef,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encodeIfPresent(value.slots, forKey: .slots)
        try container.encodeIfPresent(value.alternateCardCodes, forKey: .alternateCardCodes)
        try container.encode(value.art, forKey: .art)
        try value.locationSymbol.encode(to: &container, forKey: .locationSymbol)
        try value.locationRevealedSymbol.encode(to: &container, forKey: .locationRevealedSymbol)
        try container.encodeIfPresent(value.locationConnections, forKey: .locationConnections)
        try container.encodeIfPresent(
            value.locationRevealedConnections,
            forKey: .locationRevealedConnections
        )
        try value.purchaseTrauma.encode(to: &container, forKey: .purchaseTrauma)
        try container.encodeIfPresent(value.grantedXp, forKey: .grantedXp)
        try container.encodeIfPresent(value.canReplace, forKey: .canReplace)
        try container.encodeIfPresent(value.deckRestrictions, forKey: .deckRestrictions)
        try container.encodeIfPresent(value.bondedWith, forKey: .bondedWith)
        try container.encodeIfPresent(value.skipPlayWindows, forKey: .skipPlayWindows)
        try container.encodeIfPresent(value.beforeEffect, forKey: .beforeEffect)
        try value.customizations.encode(to: &container, forKey: .customizations)
    }

    private static func encodePart4(
        _ value: CardDef,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encodeIfPresent(value.otherSide, forKey: .otherSide)
        try container.encodeIfPresent(value.whenDiscarded, forKey: .whenDiscarded)
        try container.encodeIfPresent(value.canCommitWhenNoIcons, forKey: .canCommitWhenNoIcons)
        try container.encodeIfPresent(value.commitTrigger, forKey: .commitTrigger)
        try container.encodeIfPresent(value.meta, forKey: .meta)
        try container.encodeIfPresent(value.tags, forKey: .tags)
        try container.encodeIfPresent(value.outOfPlayEffects, forKey: .outOfPlayEffects)
        try container.encodeIfPresent(value.health, forKey: .health)
        try container.encodeIfPresent(value.fight, forKey: .fight)
        try container.encodeIfPresent(value.evade, forKey: .evade)
        try container.encodeIfPresent(value.healthDamage, forKey: .healthDamage)
        try container.encodeIfPresent(value.sanityDamage, forKey: .sanityDamage)
        try container.encodeIfPresent(value.alternateSkills, forKey: .alternateSkills)
        try container.encodeIfPresent(value.alternateErrata, forKey: .alternateErrata)
        try container.encodeIfPresent(value.errata, forKey: .errata)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try Self.encodePart1(self, into: &container)
        try Self.encodePart2(self, into: &container)
        try Self.encodePart3(self, into: &container)
        try Self.encodePart4(self, into: &container)
    }
}
