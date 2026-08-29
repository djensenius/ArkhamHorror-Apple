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

    @State private var pendingDeletion: GameID?
    @State private var presentedGameID: GameID?

    var body: some View {
        content
            .navigationTitle("Games")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
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
                    .accessibilityIdentifier(AccountAccessibilityID.gamesRefreshButton)
                }
            }
            .onAppear {
                if case .idle = model.gameListState {
                    model.refreshGames()
                }
            }
            .confirmationDialog(
                "Delete this game?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: {
                        if !$0 {
                            pendingDeletion = nil
                        }
                    }
                ),
                presenting: pendingDeletion
            ) { id in
                Button("Delete", role: .destructive) {
                    model.deleteGame(id)
                    pendingDeletion = nil
                }
                .accessibilityIdentifier(AccountAccessibilityID.gameDeleteConfirmButton)
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: { _ in
                Text("This permanently removes the game for every player.")
            }
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

    /// Pairs each row with a stable identity: a successfully decoded game's own
    /// ``GameID`` when available, falling back to its position only for a
    /// ``GameListEntry/failed(_:)`` row (which carries no identifier of its own).
    /// Using the row's own `GameID` -- rather than always keying by position --
    /// keeps a row's swipe actions/context menu/focus bound to the same game
    /// across a refresh that reorders or removes other rows, instead of SwiftUI
    /// reusing that row's view for a different game at the same position. Not
    /// `private` so a deterministic test can verify this identity assignment.
    func identifiedRows(for games: GameList) -> [IdentifiedGameListEntry] {
        games.enumerated().map { offset, entry in
            let id = entry.gameID.map(AnyHashable.init) ?? AnyHashable(offset)
            return IdentifiedGameListEntry(id: id, entry: entry)
        }
    }

    @ViewBuilder
    private func row(for entry: GameListEntry) -> some View {
        switch entry {
        case let .game(summary):
            Button {
                presentedGameID = summary.id
            } label: {
                GameRowView(game: summary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccountAccessibilityID.gameRow(for: summary.id.rawValue))
            .modifier(GameRowSwipeActions(
                gameID: summary.id, onDelete: { pendingDeletion = summary.id }
            ))
            .contextMenu {
                Button(role: .destructive) {
                    pendingDeletion = summary.id
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier(
                    AccountAccessibilityID.gameDeleteButton(for: summary.id.rawValue)
                )
            }
        case let .failed(failedEntry):
            Label(failedEntry.error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Pairs a ``GameListEntry`` with a stable per-row identity for ``ForEach``. See
/// ``GamesListView/identifiedRows(for:)``.
struct IdentifiedGameListEntry: Identifiable {
    let id: AnyHashable
    let entry: GameListEntry
}

/// Applies swipe-to-delete on platforms that support list swipe gestures (iOS,
/// iPadOS, macOS, visionOS); a no-op on tvOS, where the equivalent context menu
/// (already attached alongside this modifier) is the native, focus-driven path.
private struct GameRowSwipeActions: ViewModifier {
    let gameID: GameID
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
            content
        #else
            content.swipeActions(edge: .trailing) {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier(
                    AccountAccessibilityID.gameDeleteButton(for: gameID.rawValue)
                )
            }
        #endif
    }
}

#Preview("Games – empty") {
    NavigationStack {
        GamesListView(model: previewAppModel())
    }
}
