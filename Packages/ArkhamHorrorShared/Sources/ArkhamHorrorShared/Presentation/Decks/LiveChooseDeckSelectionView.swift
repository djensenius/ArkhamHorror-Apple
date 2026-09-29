import SwiftUI

/// Saved-deck picker for the live WebSocket `ChooseDeck` question shown when a brand-new
/// game is waiting for the player to choose their first deck.
struct LiveChooseDeckSelectionView: View {
    let model: AppModel
    let profile: ServerProfile
    let gameID: GameID

    @State private var viewModel: LobbyDeckSelectionViewModel
    @State private var isSubmitting = false

    init(model: AppModel, profile: ServerProfile, gameID: GameID) {
        self.model = model
        self.profile = profile
        self.gameID = gameID
        _viewModel = State(
            initialValue: LobbyDeckSelectionViewModel(
                profile: profile,
                deckService: model.deckService,
                tokenProvider: { try await model.currentGameLifecycleToken(for: profile) },
                sessionExpiredHandler: { await model.handleDeckSessionExpired(profile: profile) }
            )
        )
    }

    var body: some View {
        ArkhamCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose a Deck")
                    .font(.headline)
                    .foregroundStyle(ArkhamTheme.bone)
                content
            }
        }
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            HStack {
                Text("Loading saved decks…")
                Spacer()
                ProgressView().controlSize(.small)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                ArkhamFailureText(message: message)
                Button("Retry Saved Decks") {
                    Task { await viewModel.reload() }
                }
                .buttonStyle(.bordered)
            }
        case let .loaded(decks):
            if decks.isEmpty {
                Text("Import a deck from the Decks screen before choosing a deck.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(decks, id: \.id) { deck in
                    deckButton(deck)
                }
            }
        }
    }

    private func deckButton(_ deck: Deck) -> some View {
        let state = viewModel.validationState(for: deck)
        return Button {
            Task {
                isSubmitting = true
                _ = await model.chooseDeckForLivePrompt(deck, in: gameID)
                isSubmitting = false
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(deck.name)
                        .font(.headline)
                    Text(deck.investigatorName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    validationText(for: state)
                }
                Spacer()
                if isSubmitting || state == .pending {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(isSubmitting || state != .valid)
    }

    @ViewBuilder
    private func validationText(for state: LobbyDeckSelectionViewModel.ValidationState) -> some View {
        switch state {
        case .pending:
            Text("Checking server support…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .valid:
            Text("Server can play this deck's main cards.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .invalid(message), let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
