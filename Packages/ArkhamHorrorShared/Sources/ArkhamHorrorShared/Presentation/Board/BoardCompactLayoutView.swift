import SwiftUI

/// The compact-width layout (iPhone portrait, and any other compact horizontal size
/// class): one zone visible at a time, switched by a top segmented control, so every zone
/// still gets full-width space rather than being cramped into a tiny scroll region.
/// Directional focus movement stays within the visible zone exactly as it does in the
/// regular layout; switching the visible zone itself is a deliberate ``cycleZone``-
/// equivalent action, never an implicit side effect of scrolling.
struct BoardCompactLayoutView: View {
    let controller: BoardCommandController
    let focusBinding: FocusState<SemanticFocusID?>.Binding

    private var zones: [SemanticFocusZone] {
        BoardFocusGraphBuilder.nonEmptyZonesInCycleOrder(projection: controller.projection)
    }

    private var selectedZone: SemanticFocusZone {
        BoardFocusGraphBuilder.resolveCompactSelectedZone(
            focusedZone: controller.focusedZone, zones: zones
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            zoneSwitcher
            // Both axes: the Locations zone's `BoardLocationBoardView` can be wider than
            // a compact-width screen (a multi-column grid), which a vertical-only
            // ScrollView would otherwise clip with no way to reach the remaining
            // columns.
            ScrollView([.horizontal, .vertical]) {
                zoneContent(selectedZone)
                    .padding()
            }
        }
    }

    private var zoneSwitcher: some View {
        Picker("Board zone", selection: Binding(
            get: { selectedZone },
            set: { controller.selectZone($0) }
        )) {
            ForEach(zones, id: \.self) { zone in
                Text(title(for: zone)).tag(zone)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .accessibilityLabel(Text("Board zone selector"))
    }

    private func title(for zone: SemanticFocusZone) -> String {
        switch zone {
        case BoardFocusZone.scenario: "Scenario"
        case BoardFocusZone.actAgenda: "Act/Agenda"
        case BoardFocusZone.locations: "Locations"
        case BoardFocusZone.enemyLocations: "Enemies"
        case BoardFocusZone.investigators: "Investigators"
        case BoardFocusZone.chaosBag: "Chaos Bag"
        default: zone.rawValue
        }
    }

    @ViewBuilder
    private func zoneContent(_ zone: SemanticFocusZone) -> some View {
        switch zone {
        case BoardFocusZone.scenario:
            scenarioZoneContent
        case BoardFocusZone.actAgenda:
            actAgendaZoneContent
        case BoardFocusZone.locations:
            locationsZoneContent
        case BoardFocusZone.enemyLocations:
            enemyLocationsZoneContent
        case BoardFocusZone.investigators:
            investigatorsZoneContent
        case BoardFocusZone.chaosBag:
            chaosBagZoneContent
        default:
            EmptyView()
        }
    }

    private var scenarioZoneContent: some View {
        BoardScenarioHeaderView(
            scenario: controller.projection.scenario,
            hasCampaignContext: controller.projection.hasCampaignContext,
            counters: controller.projection.counters,
            isFocused: controller.coordinator.currentFocus == BoardFocusID.scenarioHeader,
            focusBinding: focusBinding,
            onOutcome: { controller.handle(focusID: $0, $1) }
        )
    }

    private var actAgendaZoneContent: some View {
        BoardActAgendaColumnView(
            acts: controller.projection.acts,
            agendas: controller.projection.agendas,
            focusedID: controller.coordinator.currentFocus,
            focusBinding: focusBinding,
            onOutcome: { controller.handle(focusID: $0, $1) }
        )
    }

    private var locationsZoneContent: some View {
        BoardLocationBoardView(
            locations: controller.projection.locations,
            layout: controller.layout,
            zoomScale: controller.zoomScale,
            focusedID: controller.coordinator.currentFocus,
            focusBinding: focusBinding,
            onOutcome: { controller.handle(focusID: $0, $1) }
        )
    }

    private var enemyLocationsZoneContent: some View {
        BoardEnemyLocationsRowView(
            enemyLocations: controller.projection.enemyLocations,
            focusedID: controller.coordinator.currentFocus,
            focusBinding: focusBinding,
            onOutcome: { controller.handle(focusID: $0, $1) }
        )
    }

    private var investigatorsZoneContent: some View {
        BoardInvestigatorRowView(
            investigators: controller.projection.investigators,
            otherInvestigatorCount: controller.projection.otherInvestigatorCount,
            killedInvestigatorCount: controller.projection.killedInvestigatorCount,
            focusedID: controller.coordinator.currentFocus,
            focusBinding: focusBinding,
            onOutcome: { controller.handle(focusID: $0, $1) }
        )
    }

    private var chaosBagZoneContent: some View {
        BoardChaosBagView(
            chaosBag: controller.projection.chaosBag,
            isFocused: controller.coordinator.currentFocus == BoardFocusID.chaosBagSummary,
            focusBinding: focusBinding,
            onOutcome: { controller.handle(focusID: $0, $1) }
        )
    }
}
