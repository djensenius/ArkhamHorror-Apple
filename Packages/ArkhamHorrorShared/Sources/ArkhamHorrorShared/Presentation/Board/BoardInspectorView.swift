import SwiftUI

/// The resolved entity content for whichever ``SemanticFocusID`` is currently inspected,
/// looked up from the live ``BoardProjection`` by a small, bounded sequence of linear
/// `first(where:)` scans across its entity arrays — never repeated decoding, and never an
/// unstable view-generated identity.
enum BoardInspectorContent {
    case scenario
    case chaosBag(BoardChaosBagSummary)
    case act(BoardActNode)
    case agenda(BoardAgendaNode)
    case location(BoardLocationNode)
    case enemyLocation(BoardEnemyLocationNode)
    case investigator(BoardInvestigatorNode)

    static func resolve(
        id: SemanticFocusID, in projection: BoardProjection
    ) -> BoardInspectorContent? {
        if id == BoardFocusID.scenarioHeader {
            return .scenario
        }
        if id == BoardFocusID.chaosBagSummary {
            return .chaosBag(projection.chaosBag)
        }
        if let act = projection.acts.first(where: { BoardFocusID.act($0.id) == id }) {
            return .act(act)
        }
        if let agenda = projection.agendas.first(where: { BoardFocusID.agenda($0.id) == id }) {
            return .agenda(agenda)
        }
        if let location = projection.locations.first(
            where: { BoardFocusID.location($0.id) == id }
        ) {
            return .location(location)
        }
        if let enemyLocation = projection.enemyLocations.first(
            where: { BoardFocusID.enemyLocation($0.id) == id }
        ) {
            return .enemyLocation(enemyLocation)
        }
        if let investigator = projection.investigators.first(
            where: { BoardFocusID.investigator($0.id) == id }
        ) {
            return .investigator(investigator)
        }
        return nil
    }
}

/// The focused-entity inspector, presented as an overlay modal over the board (matching
/// ``SemanticInputHarnessView``'s own modal convention) rather than a separate navigation
/// push, so dismissal always returns to exactly the entity that was inspected.
struct BoardInspectorView: View {
    let content: BoardInspectorContent
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture {}
            ArkhamCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title)
                        .font(.title3.bold())
                        .foregroundStyle(ArkhamTheme.bone)
                    Text(detailText)
                        .font(.body)
                        .foregroundStyle(ArkhamTheme.bone.opacity(0.85))
                    Button("Close", action: onClose)
                        .buttonStyle(.borderedProminent)
                        .tint(ArkhamTheme.accent)
                }
            }
            .frame(maxWidth: 420)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var title: String {
        switch content {
        case .scenario: "Scenario"
        case .chaosBag: "Chaos bag"
        case let .act(act): "Act \(act.sequence.side.rawValue)\(act.sequence.step)"
        case let .agenda(agenda): "Agenda \(agenda.sequence.side.rawValue)\(agenda.sequence.step)"
        case let .location(location): location.displayLabel
        case let .enemyLocation(location): location.displayLabel
        case let .investigator(investigator): investigator.displayName
        }
    }

    private var detailText: String {
        switch content {
        case .scenario: "See the scenario header for the current phase and counters."
        case let .chaosBag(summary): BoardAccessibility.summary(chaosBag: summary)
        case let .act(act): BoardAccessibility.summary(act: act)
        case let .agenda(agenda): BoardAccessibility.summary(agenda: agenda)
        case let .location(location): BoardAccessibility.summary(location: location)
        case let .enemyLocation(location): BoardAccessibility.summary(enemyLocation: location)
        case let .investigator(investigator): BoardAccessibility.summary(investigator: investigator)
        }
    }
}
