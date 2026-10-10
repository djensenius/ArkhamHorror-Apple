import SwiftUI

struct LiveChooseDeckSendAttempt: Equatable, Sendable {
    let id: UUID
    let deckID: DeckID
}

struct LiveChooseDeckSubmissionState: Equatable {
    static var sendFailureMessage: String {
        liveChooseDeckLocalized(
            "liveChooseDeck.sendFailure",
            "This deck could not be sent. Reconnect and try again."
        )
    }

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
    let heading: String

    @State private var viewModel: LobbyDeckSelectionViewModel
    @State private var submissionState = LiveChooseDeckSubmissionState()

    init(
        model: AppModel,
        profile: ServerProfile,
        gameID: GameID,
        promptKey: BasicChoicePromptKey,
        heading: String = BasicChoicePromptPresentation.liveChooseDeckGenericHeading()
    ) {
        self.model = model
        self.profile = profile
        self.gameID = gameID
        self.promptKey = promptKey
        self.heading = heading
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
                Text(heading)
                    .font(.headline)
                    .foregroundStyle(ArkhamTheme.bone)
                content
                if let restrictionNotice {
                    Text(restrictionNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let failureMessage {
                    ArkhamFailureText(message: failureMessage)
                }
            }
        }
        .task {
            await viewModel.load()
        }
        .task(id: gameID) {
            await model.refreshLiveChooseDeckRestriction(for: gameID)
        }
    }

    private var failureMessage: String? {
        model.liveChooseDeckServerFeedback(for: gameID, promptKey: promptKey) ??
            submissionState.sendFailure
    }

    private var restrictionNotice: String? {
        model.liveChooseDeckRestrictionNotice(for: gameID)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            HStack {
                Text(liveChooseDeckLocalized(
                    "liveChooseDeck.loadingSavedDecks",
                    "Loading saved decks…"
                ))
                Spacer()
                ProgressView().controlSize(.small)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                ArkhamFailureText(message: message)
                Button(liveChooseDeckLocalized(
                    "liveChooseDeck.retrySavedDecks",
                    "Retry Saved Decks"
                )) {
                    Task { await viewModel.reload() }
                }
                .buttonStyle(.bordered)
            }
        case let .loaded(decks):
            if decks.isEmpty {
                Text(liveChooseDeckLocalized(
                    "liveChooseDeck.noSavedDecks",
                    "Import a deck from the Decks screen before choosing a deck."
                ))
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
            validation: state,
            deck: deck
        )
        let restrictionError = model.liveChooseDeckRestrictionDeckError(for: deck, in: gameID)
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
                    validationText(for: state, restrictionError: restrictionError)
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
        for state: LobbyDeckSelectionViewModel.ValidationState,
        restrictionError: String?
    ) -> some View {
        if let restrictionError {
            Text(restrictionError)
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            validationStateText(for: state)
        }
    }

    @ViewBuilder
    private func validationStateText(
        for state: LobbyDeckSelectionViewModel.ValidationState
    ) -> some View {
        switch state {
        case .pending:
            Text(liveChooseDeckLocalized(
                "liveChooseDeck.checkingDeck",
                "Checking server support…"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        case .valid:
            Text(liveChooseDeckLocalized(
                "liveChooseDeck.validDeck",
                "Server can play this deck's main cards."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .invalid(message), let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
