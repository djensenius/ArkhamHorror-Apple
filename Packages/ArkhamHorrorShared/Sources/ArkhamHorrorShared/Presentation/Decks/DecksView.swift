import SwiftUI

/// Signed-in saved-deck management: list, import from ArkhamDB URL, and delete.
struct DecksView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: DecksViewModel

    init(model: AppModel, profile: ServerProfile) {
        _viewModel = State(
            initialValue: DecksViewModel(
                profile: profile,
                deckService: model.deckService,
                tokenProvider: { try await model.currentGameLifecycleToken(for: profile) }
            )
        )
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        List {
            #if !os(tvOS)
                Section("Import") {
                    TextField("ArkhamDB deck URL", text: $viewModel.importURL)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier(AccountAccessibilityID.deckImportURLField)
                    Button {
                        Task { await viewModel.importDeck() }
                    } label: {
                        HStack {
                            Label("Import Deck", systemImage: "square.and.arrow.down")
                            if viewModel.isImporting {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(!viewModel.canImport)
                    .accessibilityIdentifier(AccountAccessibilityID.deckImportButton)

                    if case let .failed(message) = viewModel.importState {
                        ArkhamFailureText(message: message)
                            .accessibilityIdentifier(AccountAccessibilityID.deckValidationErrorText)
                    }
                }
            #endif

            Section("Decks") {
                decksContent
            }
        }
        .accessibilityIdentifier(AccountAccessibilityID.deckList)
        .navigationTitle("Decks")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityIdentifier(AccountAccessibilityID.decksRefreshButton)
            }
        }
        .task {
            if case .idle = viewModel.loadState {
                await viewModel.load()
            }
        }
        .confirmationDialog(
            "Delete this deck?",
            isPresented: Binding(
                get: { viewModel.pendingDeletion != nil },
                set: {
                    if !$0 {
                        viewModel.cancelDelete()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Deck", role: .destructive) {
                Task { await viewModel.deletePendingDeck() }
            }
            .accessibilityIdentifier(AccountAccessibilityID.deckDeleteConfirmButton)
            Button("Cancel", role: .cancel) { viewModel.cancelDelete() }
        } message: {
            Text(
                "This removes the saved deck from your account. "
                    + "It does not delete it from ArkhamDB."
            )
        }
    }

    private var isLoading: Bool {
        if case .loading = viewModel.loadState {
            return true
        }
        return false
    }

    @ViewBuilder
    private var decksContent: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            HStack {
                Text("Loading decks…")
                Spacer()
                ProgressView().controlSize(.small)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                ArkhamFailureText(message: message)
                Button("Try Again") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(.bordered)
            }
        case let .loaded(decks):
            if decks.isEmpty {
                ContentUnavailableView(
                    "No Decks",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("Import an ArkhamDB deck URL to save it here.")
                )
            } else {
                ForEach(decks, id: \.id) { deck in
                    DeckRow(deck: deck, isDeleting: viewModel.deletingDeckIDs.contains(deck.id)) {
                        viewModel.requestDelete(deck)
                    }
                }
            }
        }
    }
}

private struct DeckRow: View {
    let deck: Deck
    let isDeleting: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.title2)
                .foregroundStyle(ArkhamTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(deck.name)
                    .font(.headline)
                    .foregroundStyle(ArkhamTheme.bone)
                Text(deck.investigatorName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDeleting {
                ProgressView().controlSize(.small)
            }
        }
        .swipeActions {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier(AccountAccessibilityID.deckDeleteButton(for: deck.id.rawValue))
        }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier(AccountAccessibilityID.deckDeleteButton(for: deck.id.rawValue))
        }
    }
}

#Preview("Decks") {
    NavigationStack {
        DecksView(model: previewAppModel(), profile: .hosted)
    }
    .background(ArkhamTheme.backgroundGradient)
    .foregroundStyle(ArkhamTheme.bone)
}
