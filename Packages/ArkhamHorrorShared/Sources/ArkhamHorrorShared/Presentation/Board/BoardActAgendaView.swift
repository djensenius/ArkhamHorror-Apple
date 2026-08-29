import SwiftUI

/// The act/agenda deck column — the board's single "board.actAgenda" zone, one tile per
/// act/agenda in ``BoardProjectionBuilder``'s deterministic `(deckID, sequence.step, id)`
/// order.
struct BoardActAgendaColumnView: View {
    let acts: [BoardActNode]
    let agendas: [BoardAgendaNode]
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BoardSectionHeading(title: "Act / Agenda")
            if acts.isEmpty, agendas.isEmpty {
                Text("No acts or agendas in this scenario")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(agendas) { agenda in
                    agendaTile(agenda)
                }
                ForEach(acts) { act in
                    actTile(act)
                }
            }
        }
    }

    private func actTile(_ act: BoardActNode) -> some View {
        let id = BoardFocusID.act(act.id)
        return BoardEntityTile(
            id: id,
            accessibilityLabel: BoardAccessibility.summary(act: act),
            isFocused: focusedID == id,
            focusBinding: focusBinding,
            onOutcome: onOutcome
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Act \(act.sequence.side.rawValue)\(act.sequence.step)")
                    .font(.subheadline.bold())
                    .foregroundStyle(ArkhamTheme.bone)
                Text(act.cardCode.rawValue).font(.caption2).foregroundStyle(.secondary)
                if let advanceCostSummary = act.advanceCostSummary {
                    Text(advanceCostSummary).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func agendaTile(_ agenda: BoardAgendaNode) -> some View {
        let id = BoardFocusID.agenda(agenda.id)
        return BoardEntityTile(
            id: id,
            accessibilityLabel: BoardAccessibility.summary(agenda: agenda),
            isFocused: focusedID == id,
            focusBinding: focusBinding,
            onOutcome: onOutcome
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agenda \(agenda.sequence.side.rawValue)\(agenda.sequence.step)")
                    .font(.subheadline.bold())
                    .foregroundStyle(ArkhamTheme.bone)
                Text(agenda.cardCode.rawValue).font(.caption2).foregroundStyle(.secondary)
                BoardStatBadge(systemImage: "flame.fill", value: "\(agenda.doom)")
            }
        }
    }
}
