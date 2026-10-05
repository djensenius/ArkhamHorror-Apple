import SwiftUI

/// The adaptive, native games/lobby list surface for the signed-in shell.
///
/// Renders every ``GameListLoadState`` case with an explicit presentation --
/// loading, empty, populated, recoverable error (keeping any previously loaded
/// content visible rather than flashing it away), and a per-row delete confirmation
/// -- using native `List`/toolbar/confirmation-dialog controls so tvOS remote,
/// keyboard, controller, touch, and visionOS focus all work without any custom input
/// handling. Tapping a row opens ``GameLobbyView`` for that game's lobby actions.
struct GamesListView: View {
    let model: AppModel
    @Binding var liveGamePath: [GameID]

    init(model: AppModel, liveGamePath: Binding<[GameID]> = .constant([])) {
        self.model = model
        _liveGamePath = liveGamePath
    }

    @State var pendingDeletion: GameID?
    @State private var isCreatePresented = false
    @State private var isJoinInvitePresented = false
    @State private var createHandoff = CreateGameLobbyHandoff()
    @State private var joinInviteHandoff = CreateGameLobbyHandoff()
    @State var presentedGameID: GameID?

    var body: some View {
        content
            .navigationTitle("Games")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        isCreatePresented = true
                    } label: {
                        Label("New Game", systemImage: "plus")
                    }
                    .accessibilityLabel("New game")
                    .accessibilityIdentifier(AccountAccessibilityID.createGameOpenButton)

                    Button {
                        isJoinInvitePresented = true
                    } label: {
                        Label(
                            gameLifecycleLocalized("games.joinInvite.title", "Join Game"),
                            systemImage: "person.badge.plus"
                        )
                    }
                    .accessibilityIdentifier(AccountAccessibilityID.joinGameInviteOpenButton)

                    Button {
                        model.refreshGames()
                    } label: {
                        if model.gameListState.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(model.gameListState.isLoading)
                    .accessibilityLabel(
                        model.gameListState.isLoading ? "Refreshing games" : "Refresh games"
                    )
                    .accessibilityIdentifier(AccountAccessibilityID.gamesRefreshButton)
                }
            }
            .onAppear {
                if case .idle = model.gameListState {
                    model.refreshGames()
                }
                reconcileOpenGameSurfaces()
            }
            .onChange(of: model.gameListState) { _, _ in
                reconcileOpenGameSurfaces()
            }
            .confirmationDialog(
                gameLifecycleLocalized(
                    "games.delete.confirmation.title",
                    "Are you sure you want to delete this game?"
                ),
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: {
                        if !$0 {
                            pendingDeletion = nil
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { id in
                Button(
                    gameLifecycleLocalized("games.delete.action", "Delete"),
                    role: .destructive
                ) {
                    model.deleteGame(id)
                    pendingDeletion = nil
                }
                .accessibilityLabel(
                    gameLifecycleLocalized(
                        "games.delete.action.accessibilityLabel",
                        "Delete game"
                    )
                )
                .accessibilityIdentifier(AccountAccessibilityID.gameDeleteConfirmButton)
                Button(gameLifecycleLocalized("common.cancel", "Cancel"), role: .cancel) {
                    pendingDeletion = nil
                }
            }
            .sheet(
                isPresented: $isCreatePresented,
                onDismiss: {
                    if let gameID = createHandoff.completedDismissal() {
                        presentedGameID = gameID
                    }
                },
                content: {
                    NavigationStack {
                        CreateGameSheetView(model: model) { gameID in
                            createHandoff.created(gameID)
                        }
                    }
                }
            )
            .sheet(
                isPresented: $isJoinInvitePresented,
                onDismiss: {
                    if let gameID = joinInviteHandoff.completedDismissal() {
                        presentedGameID = gameID
                    }
                },
                content: {
                    NavigationStack {
                        JoinGameInviteSheetView(model: model) { gameID in
                            joinInviteHandoff.created(gameID)
                        }
                    }
                }
            )
            .sheet(
                isPresented: Binding(
                    get: { presentedGameID != nil },
                    set: {
                        if !$0 {
                            presentedGameID = nil
                        }
                    }
                )
            ) {
                if let presentedGameID {
                    NavigationStack {
                        GameLobbyView(model: model, gameID: presentedGameID)
                    }
                }
            }
            .navigationDestination(for: GameID.self) { gameID in
                LiveGameView(model: model, gameID: gameID)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.gameListState {
        case .idle:
            ProgressView("Loading games…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loading(previous):
            if let previous, !previous.isEmpty {
                gamesList(previous)
            } else {
                ProgressView("Loading games…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case let .loaded(games):
            if games.isEmpty {
                emptyState
            } else {
                gamesList(games)
            }
        case let .failed(error, previous):
            if let previous, !previous.isEmpty {
                gamesList(previous, failure: error)
            } else {
                errorState(error)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Games Yet",
            systemImage: "gamecontroller",
            description: Text("Games you create or join will appear here.")
        )
    }

    private func errorState(_ error: GameLifecycleError) -> some View {
        ContentUnavailableView {
            Label("Couldn't Load Games", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.message)
        } actions: {
            Button("Retry") { model.refreshGames() }
                .accessibilityIdentifier(AccountAccessibilityID.gamesRetryButton)
        }
        .accessibilityIdentifier(AccountAccessibilityID.gameListFailureText)
    }

    private func gamesList(_ games: GameList, failure: GameLifecycleError? = nil) -> some View {
        List {
            if let failure {
                Section {
                    ArkhamFailureText(message: failure.message)
                        .accessibilityIdentifier(AccountAccessibilityID.gameListFailureText)
                }
            }
            Section {
                ForEach(identifiedRows(for: games)) { row in
                    self.row(for: row.entry)
                }
            }
        }
    }
}

#Preview("Games – empty") {
    NavigationStack {
        GamesListView(model: previewAppModel())
    }
}
