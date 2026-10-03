import SwiftUI

struct GameLobbyInviteSection: View {
    let gameID: GameID
    let inviteURL: URL
    @Binding var copiedInviteURL: Bool

    var body: some View {
        Section {
            inviteURLText
            if InviteClipboard.canCopy {
                copyButton
            }
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
        if !investigators.isEmpty {
            return true
        }
        switch gameState {
        case let .pending(players), let .chooseDecks(players):
            return !players.isEmpty
        case .active, .over, .unknown:
            return false
        }
    }
}

extension GameState {
    var showsEnterGameLinkInLobby: Bool {
        switch self {
        case .active, .chooseDecks:
            true
        case .pending, .over, .unknown:
            false
        }
    }
}
