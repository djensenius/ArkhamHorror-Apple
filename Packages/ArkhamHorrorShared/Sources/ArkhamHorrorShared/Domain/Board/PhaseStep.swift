/// Phantom tag distinguishing ``MythosPhaseSubstep``.
enum MythosPhaseSubstepTag: Sendable {}
/// A `MythosPhaseStep` sub-step (`Arkham.Phase.PhaseStep`).
typealias MythosPhaseSubstep = OpenStringEnum<MythosPhaseSubstepTag>

extension MythosPhaseSubstep {
    static let mythosPhaseBegins = MythosPhaseSubstep("MythosPhaseBeginsStep")
    static let placeDoomOnAgenda = MythosPhaseSubstep("PlaceDoomOnAgendaStep")
    static let checkDoomThreshold = MythosPhaseSubstep("CheckDoomThresholdStep")
    static let eachInvestigatorDrawsEncounterCard = MythosPhaseSubstep(
        "EachInvestigatorDrawsEncounterCardStep"
    )
    static let mythosPhaseWindow = MythosPhaseSubstep("MythosPhaseWindow")
    static let mythosPhaseEnds = MythosPhaseSubstep("MythosPhaseEndsStep")
}

/// Phantom tag distinguishing ``InvestigationPhaseSubstep``.
enum InvestigationPhaseSubstepTag: Sendable {}
/// An `InvestigationPhaseStep` sub-step (`Arkham.Phase.PhaseStep`).
typealias InvestigationPhaseSubstep = OpenStringEnum<InvestigationPhaseSubstepTag>

extension InvestigationPhaseSubstep {
    static let investigationPhaseBegins = InvestigationPhaseSubstep(
        "InvestigationPhaseBeginsStep"
    )
    static let investigationPhaseBeginsWindow = InvestigationPhaseSubstep(
        "InvestigationPhaseBeginsWindow"
    )
    static let nextInvestigatorsTurnBegins = InvestigationPhaseSubstep(
        "NextInvestigatorsTurnBeginsStep"
    )
    static let nextInvestigatorsTurnBeginsWindow = InvestigationPhaseSubstep(
        "NextInvestigatorsTurnBeginsWindow"
    )
    static let investigatorTakesAction = InvestigationPhaseSubstep("InvestigatorTakesActionStep")
    static let investigatorsTurnEnds = InvestigationPhaseSubstep("InvestigatorsTurnEndsStep")
    static let investigationPhaseEnds = InvestigationPhaseSubstep("InvestigationPhaseEndsStep")
}

/// Phantom tag distinguishing ``EnemyPhaseSubstep``.
enum EnemyPhaseSubstepTag: Sendable {}
/// An `EnemyPhaseStep` sub-step (`Arkham.Phase.PhaseStep`).
typealias EnemyPhaseSubstep = OpenStringEnum<EnemyPhaseSubstepTag>

extension EnemyPhaseSubstep {
    static let enemyPhaseBegins = EnemyPhaseSubstep("EnemyPhaseBeginsStep")
    static let hunterEnemiesMove = EnemyPhaseSubstep("HunterEnemiesMoveStep")
    static let resolveAttacksWindow = EnemyPhaseSubstep("ResolveAttacksWindow")
    static let resolveAttacks = EnemyPhaseSubstep("ResolveAttacksStep")
    static let afterResolveAttacksWindow = EnemyPhaseSubstep("AfterResolveAttacksWindow")
    static let enemyPhaseEnds = EnemyPhaseSubstep("EnemyPhaseEndsStep")
}

/// Phantom tag distinguishing ``UpkeepPhaseSubstep``.
enum UpkeepPhaseSubstepTag: Sendable {}
/// An `UpkeepPhaseStep` sub-step (`Arkham.Phase.PhaseStep`).
typealias UpkeepPhaseSubstep = OpenStringEnum<UpkeepPhaseSubstepTag>

extension UpkeepPhaseSubstep {
    static let upkeepPhaseBegins = UpkeepPhaseSubstep("UpkeepPhaseBeginsStep")
    static let upkeepPhaseBeginsWindow = UpkeepPhaseSubstep("UpkeepPhaseBeginsWindow")
    static let resetActions = UpkeepPhaseSubstep("ResetActionsStep")
    static let readyExhausted = UpkeepPhaseSubstep("ReadyExhaustedStep")
    static let drawCardAndGainResource = UpkeepPhaseSubstep("DrawCardAndGainResourceStep")
    static let checkHandSize = UpkeepPhaseSubstep("CheckHandSizeStep")
    static let upkeepPhaseEnds = UpkeepPhaseSubstep("UpkeepPhaseEndsStep")
}

/// The current step within the active phase (`Arkham.Phase.PhaseStep`). `nil` while
/// `gameState` is not `IsActive`-with-a-running-phase (for example `CampaignPhase` or
/// `ResolutionPhase`, which have no `PhaseStep` constructor). The four top-level tags are
/// closed in the currently governed schema; a genuinely new fifth tag decodes as
/// ``unknown(tag:rawObject:)`` rather than failing, consistent with every other additive
/// tagged union in this contract slice.
enum PhaseStep: Sendable {
    case mythos(MythosPhaseSubstep)
    case investigation(InvestigationPhaseSubstep)
    case enemy(EnemyPhaseSubstep)
    case upkeep(UpkeepPhaseSubstep)
    /// A tag not recognized by this client build. Preserves the complete raw wire object
    /// so nothing is lost; never encodable.
    case unknown(tag: String, rawObject: JSONValue)
}

extension PhaseStep: Equatable, Hashable {}

/// Thrown when encoding a ``PhaseStep`` whose tag this client build never recognized.
enum PhaseStepError: Error, Equatable, Sendable {
    case cannotEncodeUnknownTag(String)
}

/// `PublicGame.phaseStep`: `null`, or a ``PhaseStep``. Modeled as a free function pair
/// (rather than `PhaseStep?`'s own `Codable`) so ``PhaseStep`` itself never needs a
/// spurious `case none`, matching the schema's own `oneOf [null, ...]` shape exactly.
enum NullablePhaseStep {
    static func decode(from decoder: any Decoder) throws -> PhaseStep? {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            return nil
        }
        let container = try decoder.container(keyedBy: PhaseStepCodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "MythosPhaseStep":
            return try .mythos(container.decode(MythosPhaseSubstep.self, forKey: .contents))
        case "InvestigationPhaseStep":
            return try .investigation(
                container.decode(InvestigationPhaseSubstep.self, forKey: .contents)
            )
        case "EnemyPhaseStep":
            return try .enemy(container.decode(EnemyPhaseSubstep.self, forKey: .contents))
        case "UpkeepPhaseStep":
            return try .upkeep(container.decode(UpkeepPhaseSubstep.self, forKey: .contents))
        default:
            return try .unknown(tag: tag, rawObject: JSONValue(from: decoder))
        }
    }

    static func encode(_ value: PhaseStep?, to encoder: any Encoder) throws {
        guard let value else {
            var single = encoder.singleValueContainer()
            try single.encodeNil()
            return
        }
        var container = encoder.container(keyedBy: PhaseStepCodingKeys.self)
        switch value {
        case let .mythos(substep):
            try container.encode("MythosPhaseStep", forKey: .tag)
            try container.encode(substep, forKey: .contents)
        case let .investigation(substep):
            try container.encode("InvestigationPhaseStep", forKey: .tag)
            try container.encode(substep, forKey: .contents)
        case let .enemy(substep):
            try container.encode("EnemyPhaseStep", forKey: .tag)
            try container.encode(substep, forKey: .contents)
        case let .upkeep(substep):
            try container.encode("UpkeepPhaseStep", forKey: .tag)
            try container.encode(substep, forKey: .contents)
        case let .unknown(tag, _):
            throw PhaseStepError.cannotEncodeUnknownTag(tag)
        }
    }
}

enum PhaseStepCodingKeys: String, CodingKey {
    case tag
    case contents
}
