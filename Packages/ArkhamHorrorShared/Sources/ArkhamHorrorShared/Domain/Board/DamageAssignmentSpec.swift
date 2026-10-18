import Foundation

struct EnemyAttackAssignmentEnvelope {
    let enemyID: EnemyID
    let rawChoices: [JSONValue]
    let promptSpec: EnemyAttackAssignmentPromptSpec
}

struct EnemyAttackAssignmentPromptSpec {
    let label: String
    let choices: [EnemyAttackAssignmentChoiceSpec]

    static let supported = [
        EnemyAttackAssignmentPromptSpec(
            label: "Assign 1 damage and 1 horror",
            choices: [
                EnemyAttackAssignmentChoiceSpec(
                    kind: .damage,
                    direct: EnemyAttackAssignmentAmounts(damage: 1, horror: 0),
                    remaining: EnemyAttackAssignmentAmounts(damage: 0, horror: 1),
                    damageCandidates: .target,
                    horrorCandidates: .empty
                ),
                EnemyAttackAssignmentChoiceSpec(
                    kind: .horror,
                    direct: EnemyAttackAssignmentAmounts(damage: 0, horror: 1),
                    remaining: EnemyAttackAssignmentAmounts(damage: 1, horror: 0),
                    damageCandidates: .empty,
                    horrorCandidates: .target
                ),
            ]
        ),
        EnemyAttackAssignmentPromptSpec(
            label: "Assign 1 horror",
            choices: [terminalHorror]
        ),
        EnemyAttackAssignmentPromptSpec(
            label: "Assign 1 horror",
            choices: [terminalHorror, terminalHorror]
        ),
        EnemyAttackAssignmentPromptSpec(
            label: "Assign 1 damage",
            choices: [terminalDamage]
        ),
        EnemyAttackAssignmentPromptSpec(
            label: "Assign 1 damage",
            choices: [terminalDamage, terminalDamage]
        ),
    ]

    private static let terminalDamage = EnemyAttackAssignmentChoiceSpec(
        kind: .damage,
        direct: EnemyAttackAssignmentAmounts(damage: 1, horror: 0),
        remaining: EnemyAttackAssignmentAmounts(damage: 0, horror: 0),
        damageCandidates: .target,
        horrorCandidates: .targetOrEmptyWhenRemainingZero
    )

    private static let terminalHorror = EnemyAttackAssignmentChoiceSpec(
        kind: .horror,
        direct: EnemyAttackAssignmentAmounts(damage: 0, horror: 1),
        remaining: EnemyAttackAssignmentAmounts(damage: 0, horror: 0),
        damageCandidates: .targetOrEmptyWhenRemainingZero,
        horrorCandidates: .target
    )
}

struct EnemyAttackAssignmentChoiceSpec {
    let kind: EnemyAttackAssignmentKind
    let direct: EnemyAttackAssignmentAmounts
    let remaining: EnemyAttackAssignmentAmounts
    let damageCandidates: EnemyAttackAssignmentCandidateSet
    let horrorCandidates: EnemyAttackAssignmentCandidateSet
}

struct EnemyAttackAssignmentAmounts {
    let damage: Int64
    let horror: Int64
}

enum EnemyAttackAssignmentCandidateSet {
    case empty
    case target
    case targetOrEmptyWhenRemainingZero
}

extension EnemyAttackAssignmentKind {
    var tokenType: String {
        switch self {
        case .damage: "DamageToken"
        case .horror: "HorrorToken"
        }
    }
}
