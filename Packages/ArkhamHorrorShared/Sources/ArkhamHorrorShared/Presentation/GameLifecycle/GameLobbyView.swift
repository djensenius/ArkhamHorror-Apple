import SwiftUI

/// A game's lobby sheet: join a pending lobby, view and claim open seats (when the
/// server allows it for this game), and continue without upgrading a claimed seat's
/// deck while the game is waiting on deck choices.
///
/// Every action here is gated purely by this game's own typed, already-loaded state
/// (``GameState``, `hasOpenSeats`, `multiplayerVariant`) -- never a guessed or
/// synthesized rule -- and every control disables while any action is already in
/// flight for this game, so actions on the same game are always serialized.
///
/// Looks the game up by ``GameID`` from ``AppModel/gameListState`` on every render
/// (rather than capturing a `GameSummary` snapshot once) so a refresh while this
/// sheet is open -- for example after joining moves the game into
/// `.chooseDecks`, or claiming the last seat clears `hasOpenSeats` -- always shows
/// this game's current, live state instead of a stale one that could offer an
/// action the server no longer permits.
struct GameLobbyView: View {
    let model: AppModel
    let gameID: GameID
    @Environment(\.dismiss) private var dismiss

    /// This game's current summary, re-derived from the shared, process-wide games
    /// list every time this view's body is evaluated. `nil` once the game is no
    /// longer in the loaded list (deleted, or a row that failed to (re)load). Not
    /// `private` so a deterministic test can prove this re-derives live from
    /// `model.gameListState` rather than a frozen snapshot captured at init time.
    var game: GameSummary? {
        model.gameListState.games?.lazy.compactMap { entry -> GameSummary? in
            guard case let .game(summary) = entry, summary.id == gameID else { return nil }
            return summary
        }.first
    }

    var body: some View {
        Group {
            if let game {
                lobbyContent(for: game)
            } else {
                ContentUnavailableView(
                    "Game No Longer Available",
                    systemImage: "questionmark.circle",
                    description: Text("This game may have been deleted or is no longer visible.")
                )
            }
        }
        .navigationTitle("Lobby")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .navigationDestination(for: GameID.self) { gameID in
            LiveGameView(model: model, gameID: gameID)
        }
    }

    private func lobbyContent(for game: GameSummary) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(game.displayName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(ArkhamTheme.bone)
                    Text(game.displaySubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(game.gameState.statusText)
                        .font(.subheadline)
                        .foregroundStyle(ArkhamTheme.accent)
                }
            }

            if case .pending = game.gameState {
                Section {
                    joinButton
                }
            }

            if case .active = game.gameState {
                Section {
                    NavigationLink(value: gameID) {
                        Label("Enter Game", systemImage: "arrow.right.circle.fill")
                    }
                    .accessibilityIdentifier(
                        AccountAccessibilityID.liveGameEnterButton(for: gameID.rawValue)
                    )
                }
            }

            if game.hasOpenSeats, game.multiplayerVariant == .withFriends {
                Section("Open Seats") {
                    openSeatsContent
                }
            }

            if case .chooseDecks = game.gameState, !game.investigators.isEmpty {
                Section("Choose Deck") {
                    chooseDeckContent(for: game)
                }
            }

            if let failure = model.gameLifecycleActionFailures[gameID] {
                Section {
                    ArkhamFailureText(message: failure.error.message)
                        .accessibilityIdentifier(
                            AccountAccessibilityID.gameActionFailureText(for: gameID.rawValue)
                        )
                }
            }
        }
    }

    private var action: GameLifecycleAction? {
        model.gameLifecycleActions[gameID]
    }

    private var joinButton: some View {
        Button {
            model.joinGame(gameID)
        } label: {
            HStack {
                Label("Join Lobby", systemImage: "person.badge.plus")
                if action == .joining {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(action != nil)
        .accessibilityIdentifier(AccountAccessibilityID.gameJoinButton(for: gameID.rawValue))
    }

    @ViewBuilder
    private var openSeatsContent: some View {
        if let openSeats = model.gameOpenSeats[gameID] {
            if openSeats.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No open seats remain.")
                        .foregroundStyle(.secondary)
                    // A stale/racy empty result (or a transient backend issue) must
                    // never leave this lobby permanently non-retryable while
                    // `hasOpenSeats` might still legitimately be true -- this reuses
                    // the exact same action as the initial "View Open Seats" button
                    // below, so it is never a distinct, second concurrent load.
                    Button {
                        model.loadOpenSeats(for: gameID)
                    } label: {
                        HStack {
                            Text("Refresh")
                            if action == .loadingOpenSeats {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(action != nil)
                    .accessibilityIdentifier(
                        AccountAccessibilityID.gameOpenSeatsButton(for: gameID.rawValue)
                    )
                }
            } else {
                ForEach(openSeats, id: \.rawValue) { seat in
                    Button {
                        model.claimSeat(seat, in: gameID)
                    } label: {
                        Label(seat.rawValue, systemImage: "person.fill.badge.plus")
                    }
                    .disabled(action != nil)
                    .accessibilityIdentifier(
                        AccountAccessibilityID.gameClaimSeatButton(
                            for: gameID.rawValue, seat: seat.rawValue
                        )
                    )
                }
            }
        } else {
            Button {
                model.loadOpenSeats(for: gameID)
            } label: {
                HStack {
                    Text("View Open Seats")
                    if action == .loadingOpenSeats {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(action != nil)
            .accessibilityIdentifier(
                AccountAccessibilityID.gameOpenSeatsButton(for: gameID.rawValue)
            )
        }
    }

    private func chooseDeckContent(for game: GameSummary) -> some View {
        ForEach(game.investigators, id: \.id) { investigator in
            Button {
                model.continueWithoutUpgrading(investigatorId: investigator.id, in: gameID)
            } label: {
                Label(
                    "Continue as \(investigator.classSymbol.description) (\(investigator.id))",
                    systemImage: "arrow.right.circle"
                )
            }
            .disabled(action != nil)
            .accessibilityIdentifier(
                AccountAccessibilityID.gameContinueDeckButton(
                    for: gameID.rawValue, investigatorId: investigator.id
                )
            )
        }
    }
}

#Preview("Lobby – pending") {
    NavigationStack {
        GameLobbyView(model: previewAppModel(), gameID: GameID(UUID()))
    }
}
