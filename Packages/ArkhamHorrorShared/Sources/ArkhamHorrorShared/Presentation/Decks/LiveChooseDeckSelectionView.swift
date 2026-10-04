import SwiftUI

/// Saved-deck picker for the live WebSocket `ChooseDeck` question shown when a brand-new
/// game is waiting for the player to choose their first deck.
struct LiveChooseDeckSelectionView: View {
    let model: AppModel
    let profile: ServerProfile
    let gameID: GameID
    let promptKey: BasicChoicePromptKey

    @State private var viewModel: LobbyDeckSelectionViewModel
    @State private var isSubmitting = false
    @State private var sendFailure: String?

    init(model: AppModel, profile: ServerProfile, gameID: GameID, promptKey: BasicChoicePromptKey) {
        self.model = model
        self.profile = profile
        self.gameID = gameID
        self.promptKey = promptKey
        _viewModel = State(
            initialValue: LobbyDeckSelectionViewModel(
                profile: profile,
                deckService: model.deckService,
                tokenProvider: { try await model.currentDeckRequestContext(for: profile) },
                sessionExpiredHandler: { context in
                    await model.handleDeckSessionExpired(profile: profile, context: context)
                }
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
                if let failureMessage {
                    ArkhamFailureText(message: failureMessage)
                }
            }
        }
        .task {
            await viewModel.load()
        }
    }

    private var failureMessage: String? {
        model.liveChooseDeckServerFeedback(for: gameID, promptKey: promptKey) ?? sendFailure
    }

    private var isAwaitingServerAnswer: Bool {
        model.liveChooseDeckIsAwaitingAnswer(for: gameID, promptKey: promptKey)
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
                sendFailure = nil
                let didSend = await model.chooseDeckForLivePrompt(deck, in: gameID)
                if !didSend {
                    sendFailure = "This deck could not be sent. Reconnect and try again."
                }
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
        .disabled(isAwaitingServerAnswer || isSubmitting || state != .valid)
    }

    @ViewBuilder
    private func validationText(
        for state: LobbyDeckSelectionViewModel.ValidationState
    ) -> some View {
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
