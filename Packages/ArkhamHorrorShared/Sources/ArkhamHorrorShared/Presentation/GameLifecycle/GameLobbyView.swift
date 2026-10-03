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
    @State private var copiedInviteURL = false

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
                    gameLifecycleLocalized(
                        "games.lobby.unavailable.title",
                        "Game No Longer Available"
                    ),
                    systemImage: "questionmark.circle",
                    description: Text(gameLifecycleLocalized(
                        "games.lobby.unavailable.description",
                        "This game may have been deleted or is no longer visible."
                    ))
                )
            }
        }
        .navigationTitle(gameLifecycleLocalized("games.lobby.title", "Lobby"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(gameLifecycleLocalized("games.lobby.done", "Done")) { dismiss() }
            }
        }
        .navigationDestination(for: GameID.self) { gameID in
            LiveGameView(model: model, gameID: gameID)
        }
    }

    private func lobbyContent(for game: GameSummary) -> some View {
        List {
            lobbyHeaderSection(for: game)
            waitingSection(for: game)
            inviteSection(for: game)
            pendingJoinSection(for: game.gameState)
            enterGameSection(for: game.gameState)
            openSeatsSection(for: game)
            chooseDeckSection(for: game)
            failureSection
        }
        .onAppear { loadOpenSeatsIfNeeded(for: game) }
        .onChange(of: game.hasOpenSeats) { _, _ in loadOpenSeatsIfNeeded(for: game) }
    }

    private var action: GameLifecycleAction? {
        model.gameLifecycleActions[gameID]
    }

    private var joinButton: some View {
        Button {
            model.joinGame(gameID)
        } label: {
            HStack {
                Label(
                    gameLifecycleLocalized("games.lobby.join", "Join Lobby"),
                    systemImage: "person.badge.plus"
                )
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
    private func openSeatsContent(for game: GameSummary) -> some View {
        if let openSeats = model.gameOpenSeats[gameID] {
            if openSeats.isEmpty || game.viewerAlreadyHasSeat {
                VStack(alignment: .leading, spacing: 4) {
                    Text(openSeatsStatusText(for: game, openSeats: openSeats))
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
                            Text(gameLifecycleLocalized("games.lobby.openSeats.refresh", "Refresh"))
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
                    Text(gameLifecycleLocalized("games.lobby.openSeats.view", "View Open Seats"))
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

    @ViewBuilder
    private func chooseDeckContent(for game: GameSummary) -> some View {
        ForEach(game.investigators, id: \.id) { investigator in
            Button {
                model.continueWithoutUpgrading(investigatorId: investigator.id, in: gameID)
            } label: {
                Label(
                    gameLifecycleLocalizedFormat(
                        "games.lobby.chooseDeck.continueAs",
                        "Continue as %@ (%@)",
                        investigator.classSymbol.description,
                        investigator.id
                    ),
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

        if case let .signedIn(profile, _, _) = model.sessionState {
            LobbyDeckSelectionView(
                model: model,
                profile: profile,
                gameID: gameID,
                investigators: game.investigators,
                action: action
            )
        }
    }
}

extension GameLobbyView {
    func lobbyHeaderSection(for game: GameSummary) -> some View {
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
    }

    @ViewBuilder
    func waitingSection(for game: GameSummary) -> some View {
        if let waitingText = waitingText(for: game) {
            Section {
                Text(waitingText)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    func inviteSection(for game: GameSummary) -> some View {
        if let invite = inviteURL(for: game) {
            GameLobbyInviteSection(
                gameID: gameID,
                inviteURL: invite,
                copiedInviteURL: $copiedInviteURL
            )
        }
    }

    @ViewBuilder
    func pendingJoinSection(for state: GameState) -> some View {
        if case .pending = state {
            Section { joinButton }
        }
    }

    @ViewBuilder
    func enterGameSection(for state: GameState) -> some View {
        if state.showsEnterGameLinkInLobby {
            Section {
                NavigationLink(value: gameID) {
                    Label(
                        gameLifecycleLocalized("games.lobby.enterGame", "Enter Game"),
                        systemImage: "arrow.right.circle.fill"
                    )
                }
                .accessibilityIdentifier(
                    AccountAccessibilityID.liveGameEnterButton(for: gameID.rawValue)
                )
            }
        }
    }

    @ViewBuilder
    func openSeatsSection(for game: GameSummary) -> some View {
        if game.hasOpenSeats, game.multiplayerVariant == .withFriends {
            Section(gameLifecycleLocalized("games.lobby.openSeats.section", "Open Seats")) {
                openSeatsContent(for: game)
            }
        }
    }

    @ViewBuilder
    func chooseDeckSection(for game: GameSummary) -> some View {
        if case .chooseDecks = game.gameState, !game.investigators.isEmpty {
            Section(gameLifecycleLocalized("games.lobby.chooseDeck.section", "Choose Deck")) {
                chooseDeckContent(for: game)
            }
        }
    }

    @ViewBuilder
    var failureSection: some View {
        if let failure = model.gameLifecycleActionFailures[gameID] {
            Section {
                ArkhamFailureText(message: failure.error.message)
                    .accessibilityIdentifier(
                        AccountAccessibilityID.gameActionFailureText(for: gameID.rawValue)
                    )
            }
        }
    }

    var signedInProfile: ServerProfile? {
        guard case let .signedIn(profile, _, _) = model.sessionState else { return nil }
        return profile
    }

    func waitingText(for game: GameSummary) -> String? {
        switch game.gameState {
        case let .pending(players):
            let knownSeatCount = game.investigators.count + game.otherInvestigators.count
            guard knownSeatCount > 0 else {
                return gameLifecycleLocalized(
                    "games.lobby.waiting.pending.unknownRemaining",
                    "Waiting for more players to join."
                )
            }
            let remaining = max(knownSeatCount - players.count, 0)
            return gameLifecycleLocalizedPlural(
                count: remaining,
                oneKey: "games.lobby.waiting.pending.remaining.one",
                oneFallback: "Waiting for 1 more player to join.",
                manyKey: "games.lobby.waiting.pending.remaining.many",
                manyFallback: "Waiting for %lld more players to join."
            )
        case let .chooseDecks(players):
            return gameLifecycleLocalizedPlural(
                count: players.count,
                oneKey: "games.lobby.waiting.chooseDecks.one",
                oneFallback: "Waiting for 1 player's deck choice.",
                manyKey: "games.lobby.waiting.chooseDecks.many",
                manyFallback: "Waiting for %lld players' deck choices."
            )
        case .active, .over, .unknown:
            return nil
        }
    }

    func openSeatsStatusText(for game: GameSummary, openSeats: OpenSeats) -> String {
        if game.viewerAlreadyHasSeat {
            return gameLifecycleLocalized(
                "games.lobby.openSeats.alreadyClaimed",
                "You already have a seat in this game."
            )
        }
        if openSeats.isEmpty {
            return gameLifecycleLocalized(
                "games.lobby.openSeats.empty",
                "No open seats remain."
            )
        }
        return ""
    }

    func inviteURL(for game: GameSummary) -> URL? {
        guard game.multiplayerVariant == .withFriends, let profile = signedInProfile else {
            return nil
        }
        guard case .pending = game.gameState else { return nil }
        let investigators = game.investigators + game.otherInvestigators
        let route: GameInvite.Route = investigators.isEmpty ? .join : .claimSeat
        return GameInvite.webURL(for: gameID, route: route, on: profile)
    }

    func loadOpenSeatsIfNeeded(for game: GameSummary) {
        guard game.hasOpenSeats,
              game.multiplayerVariant == .withFriends,
              model.gameOpenSeats[gameID] == nil,
              action == nil
        else { return }
        model.loadOpenSeats(for: gameID)
    }
}

private struct GameLobbyInviteSection: View {
    let gameID: GameID
    let inviteURL: URL
    @Binding var copiedInviteURL: Bool

    var body: some View {
        Section {
            inviteURLText
            copyButton
        } header: {
            Text(gameLifecycleLocalized("games.lobby.invite.section", "Invite Others"))
        } footer: {
            Text(gameLifecycleLocalized(
                "games.lobby.invite.footer",
                "Friends can open this web-compatible link to join or claim a seat."
            ))
        }
    }

    @ViewBuilder
    private var inviteURLText: some View {
        let text = Text(inviteURL.absoluteString)
            .font(.footnote.monospaced())
            .accessibilityIdentifier(
                AccountAccessibilityID.gameInviteURLText(for: gameID.rawValue)
            )
        #if os(tvOS)
            text
        #else
            text.textSelection(.enabled)
        #endif
    }

    private var copyButton: some View {
        Button {
            InviteClipboard.copy(inviteURL.absoluteString)
            copiedInviteURL = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                copiedInviteURL = false
            }
        } label: {
            Label(
                copiedInviteURL
                    ? gameLifecycleLocalized("games.lobby.invite.copied", "Copied")
                    : gameLifecycleLocalized("games.lobby.invite.copy", "Copy Invite Link"),
                systemImage: copiedInviteURL ? "checkmark" : "doc.on.doc"
            )
        }
        .accessibilityIdentifier(
            AccountAccessibilityID.gameInviteCopyButton(for: gameID.rawValue)
        )
    }
}

extension GameSummary {
    var viewerAlreadyHasSeat: Bool {
        if !investigators.isEmpty { return true }
        switch gameState {
        case let .pending(players), let .chooseDecks(players):
            return !players.isEmpty
        case .active, .over, .unknown:
            return false
        }
    }
}

private extension GameState {
    var showsEnterGameLinkInLobby: Bool {
        switch self {
        case .active, .chooseDecks:
            true
        case .pending, .over, .unknown:
            false
        }
    }
}

#Preview("Lobby – pending") {
    NavigationStack {
        GameLobbyView(model: previewAppModel(), gameID: GameID(UUID()))
    }
}
