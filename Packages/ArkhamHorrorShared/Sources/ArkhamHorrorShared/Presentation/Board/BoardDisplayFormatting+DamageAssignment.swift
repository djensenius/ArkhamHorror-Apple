import Foundation

extension BoardDisplayFormatting {
    static func enemyAttackAssignmentDisplayTitle(
        _ assignment: EnemyAttackDamageAssignment,
        fallback: String,
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
        guard let targetName else { return fallback }
        return "\(assignment.kind.actionTitle) to \(targetName)"
    }
}
