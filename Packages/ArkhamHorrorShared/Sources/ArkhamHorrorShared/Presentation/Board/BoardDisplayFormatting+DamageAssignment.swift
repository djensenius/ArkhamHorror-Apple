import Foundation

extension BoardDisplayFormatting {
    static func enemyAttackAssignmentDisplayTitle(
        _ assignment: EnemyAttackDamageAssignment,
        fallback _: String,
        in projection: BoardProjection
    ) -> String {
        let targetName: String? = switch assignment.target {
        case let .investigator(investigatorID):
            projection.investigators.first { $0.id == investigatorID }?.displayName
        case let .asset(assetID):
            projection.inPlayCardsByPlayer.values.flatMap(\.self).first {
                $0.id == .asset(assetID)
            }?.displayName
        }
        return localizedAssignmentDisplayTitle(
            for: assignment.kind,
            targetName: targetName ?? BoardLocalization.localized(
                "board.damageAssignment.targetUnavailable", "unavailable target"
            )
        )
    }

    private static func localizedAssignmentDisplayTitle(
        for kind: EnemyAttackAssignmentKind,
        targetName: String
    ) -> String {
        let (key, fallback) = switch kind {
        case .damage:
            (
                "board.damageAssignment.assignOneDamage",
                "Assign 1 damage to \(targetName)"
            )
        case .horror:
            (
                "board.damageAssignment.assignOneHorror",
                "Assign 1 horror to \(targetName)"
            )
        }
        let format = BoardLocalization.localized(key, fallback)
        guard format != fallback else { return fallback }
        return String(format: format, locale: Locale.current, targetName)
    }
}
