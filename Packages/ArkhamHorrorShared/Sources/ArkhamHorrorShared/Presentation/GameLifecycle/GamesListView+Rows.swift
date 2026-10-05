import SwiftUI

extension GamesListView {
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

    func reconcileOpenGameSurfaces() {
        guard case let .loaded(games) = model.gameListState else { return }
        let reconciled = OpenGameSurfaceReconciler.reconciled(
            presentedGameID: presentedGameID,
            liveGamePath: liveGamePath,
            games: games,
            confirmedDeletedGameIDs: model.confirmedDeletedGameIDs
        )
        presentedGameID = reconciled.presentedGameID
        liveGamePath = reconciled.liveGamePath
    }

    func deleteFailurePresentation(for gameID: GameID) -> GameRowActionFailurePresentation? {
        guard
            let failure = model.gameLifecycleActionFailures[gameID],
            failure.action == .deleting
        else { return nil }
        let message = failure.error.message
        return GameRowActionFailurePresentation(
            message: message,
            accessibilityLabel: gameLifecycleLocalizedFormat(
                "games.delete.failure.accessibilityLabel",
                "Delete failed: %@",
                message
            ),
            accessibilityIdentifier: AccountAccessibilityID.gameActionFailureText(
                for: gameID.rawValue
            )
        )
    }

    @ViewBuilder
    func row(for entry: GameListEntry) -> some View {
        switch entry {
        case let .game(summary):
            // Neither the swipe nor the context-menu delete action is legal while
            // another lifecycle action (join/open-seats/claim-seat/choose-deck, or
            // an already-in-flight delete) is running for this exact game --
            // triggering delete then would silently supersede and cancel that other
            // action rather than confirming an explicit, intentional delete.
            let actionInFlight = model.gameLifecycleActions[summary.id] != nil
            let deleteFailure = deleteFailurePresentation(for: summary.id)
            // `rowButton(for:)` already applies `liveGameEnterButton` to live-board
            // navigation rows; a later `.accessibilityIdentifier` on the same node
            // would silently override it, making that identifier unreachable, so only
            // lobby-sheet button rows are stamped with `gameRow` here.
            Group {
                if summary.gameState.opensLiveGameView {
                    rowButton(for: summary, actionFailure: deleteFailure)
                } else {
                    rowButton(for: summary, actionFailure: deleteFailure)
                        .accessibilityIdentifier(
                            AccountAccessibilityID.gameRow(for: summary.id.rawValue)
                        )
                }
            }
            .buttonStyle(.plain)
            .modifier(GameRowSwipeActions(
                gameID: summary.id, isDeleteDisabled: actionInFlight,
                onDelete: { pendingDeletion = summary.id }
            ))
            .contextMenu {
                Button(role: .destructive) {
                    pendingDeletion = summary.id
                } label: {
                    Label(
                        gameLifecycleLocalized("games.delete.action", "Delete"),
                        systemImage: "trash"
                    )
                }
                .disabled(actionInFlight)
                .accessibilityLabel(
                    gameLifecycleLocalized(
                        "games.delete.action.accessibilityLabel",
                        "Delete game"
                    )
                )
                .accessibilityHint(
                    gameLifecycleLocalized(
                        "games.delete.action.accessibilityHint",
                        "Asks for confirmation before deleting this game."
                    )
                )
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

    /// A game already ``GameState/active`` navigates straight into its live board
    /// (via `NavigationLink(value:)`, resolved by `GamesListView`'s own
    /// `.navigationDestination(for: GameID.self)`). Pending and choose-deck games keep
    /// opening the lobby sheet so join/open-seat/deck-upgrade actions remain reachable;
    /// that sheet offers its own Enter Game link when a live deck prompt is needed.
    @ViewBuilder
    private func rowButton(
        for summary: GameSummary,
        actionFailure: GameRowActionFailurePresentation?
    ) -> some View {
        if summary.gameState.opensLiveGameView {
            NavigationLink(value: summary.id) {
                GameRowView(game: summary, actionFailure: actionFailure)
            }
            .accessibilityIdentifier(
                AccountAccessibilityID.liveGameEnterButton(for: summary.id.rawValue)
            )
        } else {
            Button {
                presentedGameID = summary.id
            } label: {
                GameRowView(game: summary, actionFailure: actionFailure)
            }
        }
    }
}

struct OpenGameSurfaceReconciliation: Equatable {
    let presentedGameID: GameID?
    let liveGamePath: [GameID]
}

enum OpenGameSurfaceReconciler {
    static func reconciled(
        presentedGameID: GameID?,
        liveGamePath: [GameID],
        games: GameList,
        confirmedDeletedGameIDs: Set<GameID>
    ) -> OpenGameSurfaceReconciliation {
        let shouldClosePresentedGame = presentedGameID.map {
            shouldClose($0, in: games, confirmedDeletedGameIDs: confirmedDeletedGameIDs)
        } ?? false
        let reconciledPresentedGameID: GameID? = shouldClosePresentedGame ? nil : presentedGameID
        let reconciledLiveGamePath = liveGamePath.filter {
            !shouldClose($0, in: games, confirmedDeletedGameIDs: confirmedDeletedGameIDs)
        }
        return OpenGameSurfaceReconciliation(
            presentedGameID: reconciledPresentedGameID,
            liveGamePath: reconciledLiveGamePath
        )
    }

    static func reconcile(
        presentedGameID: inout GameID?,
        liveGamePath: inout [GameID],
        games: GameList,
        confirmedDeletedGameIDs: Set<GameID>
    ) {
        let result = reconciled(
            presentedGameID: presentedGameID,
            liveGamePath: liveGamePath,
            games: games,
            confirmedDeletedGameIDs: confirmedDeletedGameIDs
        )
        presentedGameID = result.presentedGameID
        liveGamePath = result.liveGamePath
    }

    private static func shouldClose(
        _ gameID: GameID,
        in games: GameList,
        confirmedDeletedGameIDs: Set<GameID>
    ) -> Bool {
        guard !games.containsGame(gameID) else { return false }
        return confirmedDeletedGameIDs.contains(gameID) || games.hasNoFailedEntries
    }
}

private extension [GameListEntry] {
    func containsGame(_ id: GameID) -> Bool {
        contains { $0.gameID == id }
    }

    var hasNoFailedEntries: Bool {
        !contains { entry in
            switch entry {
            case .failed:
                true
            case .game:
                false
            }
        }
    }
}

/// Pairs a ``GameListEntry`` with a stable per-row identity for ``ForEach``. See
/// ``GamesListView/identifiedRows(for:)``.
struct IdentifiedGameListEntry: Identifiable {
    let id: AnyHashable
    let entry: GameListEntry
}

/// Defers lobby presentation for a newly created game until the create sheet has
/// actually dismissed, avoiding competing SwiftUI sheet presentations.
struct CreateGameLobbyHandoff: Equatable {
    private(set) var pendingGameID: GameID?

    mutating func created(_ gameID: GameID) {
        pendingGameID = gameID
    }

    mutating func completedDismissal() -> GameID? {
        defer { pendingGameID = nil }
        return pendingGameID
    }
}

/// Applies swipe-to-delete on platforms that support list swipe gestures (iOS,
/// iPadOS, macOS, visionOS); a no-op on tvOS, where the equivalent context menu
/// (already attached alongside this modifier) is the native, focus-driven path.
private struct GameRowSwipeActions: ViewModifier {
    let gameID: GameID
    let isDeleteDisabled: Bool
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
            content
        #else
            content.swipeActions(edge: .trailing) {
                Button(role: .destructive, action: onDelete) {
                    Label(
                        gameLifecycleLocalized("games.delete.action", "Delete"),
                        systemImage: "trash"
                    )
                }
                .disabled(isDeleteDisabled)
                .accessibilityLabel(
                    gameLifecycleLocalized(
                        "games.delete.action.accessibilityLabel",
                        "Delete game"
                    )
                )
                .accessibilityHint(
                    gameLifecycleLocalized(
                        "games.delete.action.accessibilityHint",
                        "Asks for confirmation before deleting this game."
                    )
                )
                .accessibilityIdentifier(
                    AccountAccessibilityID.gameDeleteButton(for: gameID.rawValue)
                )
            }
        #endif
    }
}

extension GameState {
    var opensLiveGameView: Bool {
        switch self {
        case .active:
            true
        case .pending, .chooseDecks, .over, .unknown:
            false
        }
    }
}
