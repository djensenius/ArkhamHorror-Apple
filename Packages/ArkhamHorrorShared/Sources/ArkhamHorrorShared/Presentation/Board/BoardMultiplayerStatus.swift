import SwiftUI

/// Display-only multiplayer status derived from server-published board fields.
///
/// This type intentionally reads only ``BoardProjection`` values copied from the server:
/// active/turn/lead investigator flags, `playerOrder`-ordered investigators, and the
/// per-player question map projected as `hasPendingPrompt`. It never infers whose turn is
/// next and never inspects another player's prompt payload.
struct BoardMultiplayerStatus: Sendable, Equatable {
    let playerOrderCount: Int
    let activeInvestigatorName: String?
    let turnInvestigatorName: String?
    let leadInvestigatorName: String?
    let pendingPromptNames: [String]
    let localPlayerID: PlayerID?
    let localHasPendingPrompt: Bool

    init(projection: BoardProjection, localPlayerID: PlayerID?) {
        playerOrderCount = projection.playerOrderCount
        activeInvestigatorName = projection.investigators
            .first(where: \.isActingPlayer)?.displayName
        turnInvestigatorName = projection.investigators
            .first(where: \.isTurnPlayer)?.displayName
        leadInvestigatorName = projection.investigators
            .first(where: \.isLeadInvestigator)?.displayName
        pendingPromptNames = projection.investigators
            .filter(\.hasPendingPrompt)
            .map(\.displayName)
        self.localPlayerID = localPlayerID
        localHasPendingPrompt = localPlayerID.map { projection.questions[$0] != nil } ?? false
    }

    var isMultiplayer: Bool {
        playerOrderCount > 1
    }

    var shouldShowPromptSurface: Bool {
        isMultiplayer
    }

    var title: String {
        BoardLocalization.localized(
            "board.multiplayer.status.title",
            "Multiplayer status"
        )
    }

    var actingText: String {
        BoardLocalization.format(
            "board.multiplayer.status.active",
            "Acting: %@",
            activeInvestigatorName ?? unknownInvestigatorText
        )
    }

    var turnText: String {
        BoardLocalization.format(
            "board.multiplayer.status.turn",
            "Turn: %@",
            turnInvestigatorName ?? noTurnInvestigatorText
        )
    }

    var leadText: String {
        BoardLocalization.format(
            "board.multiplayer.status.lead",
            "Lead: %@",
            leadInvestigatorName ?? unknownInvestigatorText
        )
    }

    var pendingPromptText: String {
        let names = localizedList(pendingPromptNames)
        switch pendingPromptNames.count {
        case 0:
            return BoardLocalization.localized(
                "board.multiplayer.status.pending.none",
                "No pending prompts"
            )
        case 1:
            return BoardLocalization.format(
                "board.multiplayer.status.pending.one",
                "Pending prompt: %@",
                names
            )
        default:
            return BoardLocalization.format(
                "board.multiplayer.status.pending.many",
                "Pending prompts: %@",
                names
            )
        }
    }

    var localPromptText: String? {
        guard isMultiplayer else { return nil }
        if localHasPendingPrompt {
            return BoardLocalization.localized(
                "board.multiplayer.status.local.ready",
                "Your prompt is ready."
            )
        }
        guard !pendingPromptNames.isEmpty else { return nil }
        let names = localizedList(pendingPromptNames)
        if localPlayerID == nil {
            return BoardLocalization.format(
                "board.multiplayer.status.waiting.identityUnknown",
                "Waiting for %@.",
                names
            )
        }
        return BoardLocalization.format(
            "board.multiplayer.status.waiting.players",
            "Waiting for %@.",
            names
        )
    }

    var accessibilityLabel: String {
        let parts = [title, actingText, turnText, leadText, pendingPromptText]
            + [localPromptText].compactMap(\.self)
        return parts.joined(separator: ". ")
    }

    private var unknownInvestigatorText: String {
        BoardLocalization.localized(
            "board.multiplayer.status.investigator.unknown",
            "Unknown investigator"
        )
    }

    private var noTurnInvestigatorText: String {
        BoardLocalization.localized(
            "board.multiplayer.status.turn.none",
            "No turn investigator"
        )
    }

    private func localizedList(_ names: [String]) -> String {
        switch names.count {
        case 0:
            return ""
        case 1:
            return names[0]
        case 2:
            return BoardLocalization.format(
                "board.multiplayer.list.two",
                "%1$@ and %2$@",
                names[0],
                names[1]
            )
        default:
            let prefix = names.dropLast().joined(separator: ", ")
            return BoardLocalization.format(
                "board.multiplayer.list.final",
                "%1$@, and %2$@",
                prefix,
                names[names.count - 1]
            )
        }
    }
}

struct BoardMultiplayerPromptStatusView: View {
    let status: BoardMultiplayerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(status.title, systemImage: "person.3.sequence.fill")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.actingText)
                Text(status.turnText)
                Text(status.leadText)
                Text(status.pendingPromptText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let localPromptText = status.localPromptText {
                Label(
                    localPromptText,
                    systemImage: status.localHasPendingPrompt ? "bell.fill" : "hourglass"
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(status.localHasPendingPrompt ? ArkhamTheme.accent : .secondary)
                .accessibilityIdentifier("liveGame.prompt.multiplayerStatus.waiting")
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status.accessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("liveGame.prompt.multiplayerStatus")
    }
}
