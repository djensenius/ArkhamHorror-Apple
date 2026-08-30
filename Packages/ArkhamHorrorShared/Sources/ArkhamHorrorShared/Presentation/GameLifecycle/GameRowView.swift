import SwiftUI

/// A single game's semantic summary row: scenario/campaign name, difficulty and
/// multiplayer mode, lifecycle status, investigator class symbols, and an open-seats
/// indicator. Never renders a raw identifier or JSON fragment.
struct GameRowView: View {
    let game: GameSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(game.displayName)
                    .font(.headline)
                    .foregroundStyle(ArkhamTheme.bone)
                Text(game.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(ArkhamTheme.bone.opacity(0.6))
                Text(game.gameState.statusText)
                    .font(.caption)
                    .foregroundStyle(ArkhamTheme.accent)
                if !game.investigators.isEmpty {
                    investigatorRow
                }
            }
            Spacer()
            if game.hasOpenSeats {
                Label("Open Seat", systemImage: "person.badge.plus")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(ArkhamTheme.accent)
                    .accessibilityLabel("This game has an open seat")
            }
        }
        .contentShape(Rectangle())
    }

    private var investigatorRow: some View {
        HStack(spacing: 4) {
            ForEach(game.investigators, id: \.id) { investigator in
                Image(systemName: "person.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(investigator.classSymbol.description) investigator")
            }
        }
    }
}

#Preview("Game row") {
    List {
        GameRowView(
            game: GameSummary(
                id: GameID(UUID()),
                scenario: ScenarioSummary(
                    id: "01104", difficulty: .easy,
                    name: CardName(title: "The Gathering", subtitle: nil), variant: nil
                ),
                campaign: nil,
                gameState: .pending([]),
                name: "Preview game",
                investigators: [
                    InvestigatorSummary(id: "01001", classSymbol: .init("Guardian")),
                ],
                otherInvestigators: [],
                multiplayerVariant: .solo,
                hasOpenSeats: false
            )
        )
    }
}
