import SwiftUI

struct LiveChooseDeckSendAttempt: Equatable, Sendable {
    let id: UUID
    let deckID: DeckID
}

struct LiveChooseDeckSubmissionState: Equatable {
    static let sendFailureMessage = "This deck could not be sent. Reconnect and try again."

    private(set) var activeAttempt: LiveChooseDeckSendAttempt?
    private(set) var sendFailure: String?

    func isSending(deckID: DeckID) -> Bool {
        activeAttempt?.deckID == deckID
    }

    mutating func beginSending(
        deckID: DeckID,
        attemptID: UUID = UUID()
    ) -> LiveChooseDeckSendAttempt? {
        guard activeAttempt == nil else { return nil }
        let attempt = LiveChooseDeckSendAttempt(id: attemptID, deckID: deckID)
        activeAttempt = attempt
        sendFailure = nil
        return attempt
    }

    mutating func releaseActiveAttemptIfPickerEnabled(_ pickerEnabled: Bool) {
        guard pickerEnabled else { return }
        activeAttempt = nil
    }

    mutating func finish(_ attempt: LiveChooseDeckSendAttempt, didSend: Bool) {
        guard activeAttempt == attempt else { return }
        if !didSend {
            sendFailure = Self.sendFailureMessage
        }
        activeAttempt = nil
    }
}

/// Saved-deck picker for the live WebSocket `ChooseDeck` question shown when a brand-new
/// game is waiting for the player to choose their first deck.
struct LiveChooseDeckSelectionView: View {
    let model: AppModel
    let profile: ServerProfile
    let gameID: GameID
    let promptKey: BasicChoicePromptKey

    @State private var viewModel: LobbyDeckSelectionViewModel
    @State private var submissionState = LiveChooseDeckSubmissionState()

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
        model.liveChooseDeckServerFeedback(for: gameID, promptKey: promptKey) ??
            submissionState.sendFailure
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
        let pickerEnabled = model.liveChooseDeckPickerEnabled(
            for: gameID,
            promptKey: promptKey,
            validation: state
        )
        return Button {
            guard pickerEnabled,
                  let attempt = submissionState.beginSending(deckID: deck.id)
            else { return }
            Task {
                let didSend = await model.chooseDeckForLivePrompt(deck, in: gameID)
                submissionState.finish(attempt, didSend: didSend)
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
                if submissionState.isSending(deckID: deck.id) || state == .pending {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(!pickerEnabled)
        .onChange(of: pickerEnabled) { _, isEnabled in
            submissionState.releaseActiveAttemptIfPickerEnabled(isEnabled)
        }
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
