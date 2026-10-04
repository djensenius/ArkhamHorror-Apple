import SwiftUI

/// Saved-deck picker embedded in ``GameLobbyView`` while the server is waiting for
/// players to choose decks.
struct LobbyDeckSelectionView: View {
    let model: AppModel
    let profile: ServerProfile
    let gameID: GameID
    let investigators: [InvestigatorSummary]
    let action: GameLifecycleAction?

    @State private var viewModel: LobbyDeckSelectionViewModel

    init(
        model: AppModel,
        profile: ServerProfile,
        gameID: GameID,
        investigators: [InvestigatorSummary],
        action: GameLifecycleAction?
    ) {
        self.model = model
        self.profile = profile
        self.gameID = gameID
        self.investigators = investigators
        self.action = action
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
        VStack(alignment: .leading, spacing: 8) {
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
                        Task { await viewModel.reload(allowedInvestigatorIDs: allowedIDs) }
                    }
                    .buttonStyle(.bordered)
                }
            case let .loaded(decks):
                if decks.isEmpty {
                    Text("No saved decks match a claimed investigator.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(decks, id: \.id) { deck in
                        deckButton(deck)
                    }
                }
            }
        }
        .task {
            await viewModel.load(allowedInvestigatorIDs: allowedIDs)
        }
    }

    private var allowedIDs: Set<String> {
        Set(investigators.map { Deck.normalizedInvestigatorCode($0.id) })
    }

    @ViewBuilder
    private func deckButton(_ deck: Deck) -> some View {
        let state = viewModel.validationState(for: deck)
        let investigatorID = viewModel.claimedInvestigatorID(for: deck, in: investigators)
        Button {
            performLobbyDeckRowTap(deck: deck, investigatorID: investigatorID)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(ArkhamTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use \(deck.name)")
                        .font(.headline)
                    Text(deck.investigatorName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    validationText(for: state, deck: deck)
                }
                Spacer()
                if action == .choosingDeck || state == .pending {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(action != nil || state != .valid || investigatorID == nil)
        .accessibilityIdentifier(AccountAccessibilityID.lobbyDeckButton(
            for: gameID.rawValue, deckID: deck.id.rawValue
        ))
    }

    func performLobbyDeckRowTapForTesting(deck: Deck, investigatorID: String?) {
        performLobbyDeckRowTap(deck: deck, investigatorID: investigatorID)
    }

    private func performLobbyDeckRowTap(deck: Deck, investigatorID: String?) {
        if let investigatorID {
            model.chooseDeck(deck, investigatorId: investigatorID, in: gameID)
        }
    }

    @ViewBuilder
    private func validationText(
        for state: LobbyDeckSelectionViewModel.ValidationState, deck: Deck
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
                .accessibilityIdentifier(AccountAccessibilityID.lobbyDeckValidationText(
                    for: gameID.rawValue,
                    deckID: deck.id.rawValue
                ))
        }
    }
}
