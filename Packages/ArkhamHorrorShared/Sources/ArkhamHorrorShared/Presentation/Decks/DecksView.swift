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
                deckSyncTracker: model.deckSyncTracker,
                tokenProvider: { try await model.currentDeckRequestContext(for: profile) },
                sessionExpiredHandler: { context in
                    await model.handleDeckSessionExpired(profile: profile, context: context)
                },
                syncedDeckRecorder: { deck in
                    model.recordSyncedDeckForChoice(deck)
                }
            )
        )
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        List {
            #if !os(tvOS)
                Section("Import") {
                    importURLField(text: $viewModel.importURL)
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
                if let syncAllSummary = viewModel.syncAllSummary {
                    Text(syncAllSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccountAccessibilityID.deckSyncAllSummaryText)
                }
                if let deletionFailure = viewModel.deletionFailure {
                    ArkhamFailureText(message: deletionFailure)
                }
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
                    Task { await viewModel.refreshAndSync() }
                } label: {
                    Label(
                        deckLocalized("deck.refreshAndSync", "Refresh & Sync"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(isBusy)
                .accessibilityIdentifier(AccountAccessibilityID.decksRefreshButton)
            }
        }
        .refreshable {
            await viewModel.refreshAndSync()
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
            titleVisibility: .visible,
            presenting: viewModel.pendingDeletion
        ) { deck in
            Button("Delete Deck", role: .destructive) {
                Task { await viewModel.delete(deck) }
            }
            .accessibilityIdentifier(AccountAccessibilityID.deckDeleteConfirmButton)
            Button("Cancel", role: .cancel) { viewModel.cancelDelete() }
        } message: { deck in
            Text(
                "This removes \(deck.name) from your account. "
                    + "It does not delete it from ArkhamDB."
            )
        }
    }

    private func importURLField(text: Binding<String>) -> some View {
        TextField("ArkhamDB deck URL", text: text)
        #if os(iOS) || os(visionOS)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
        #endif
            .autocorrectionDisabled()
            .accessibilityIdentifier(AccountAccessibilityID.deckImportURLField)
    }

    private var isBusy: Bool {
        if case .loading = viewModel.loadState {
            return true
        }
        return viewModel.isSyncingAll
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
                    DeckRow(
                        deck: deck,
                        isDeleting: viewModel.deletingDeckIDs.contains(deck.id),
                        syncState: viewModel.syncState(for: deck),
                        onSync: { Task { await viewModel.sync(deck) } },
                        onDelete: { viewModel.requestDelete(deck) }
                    )
                }
            }
        }
    }
}

private struct DeckRow: View {
    let deck: Deck
    let isDeleting: Bool
    let syncState: DecksViewModel.SyncState?
    let onSync: () -> Void
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
                syncStatusText
            }
            Spacer()
            rowActions
        }
    }

    @ViewBuilder
    private var syncStatusText: some View {
        switch syncState {
        case .syncing:
            Text(deckLocalized("deck.sync.status.syncing", "Syncing…"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    AccountAccessibilityID.deckSyncStatusText(for: deck.id.rawValue)
                )
        case let .succeeded(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityIdentifier(
                    AccountAccessibilityID.deckSyncStatusText(for: deck.id.rawValue)
                )
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier(
                    AccountAccessibilityID.deckSyncStatusText(for: deck.id.rawValue)
                )
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var rowActions: some View {
        if isDeleting {
            ProgressView().controlSize(.small)
        } else {
            HStack(spacing: 8) {
                if deck.hasSyncURL {
                    Button(action: onSync) {
                        Label(
                            deckLocalized("deck.sync.action", "Sync"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(syncState == .syncing)
                    .accessibilityLabel(deckLocalizedFormat(
                        "deck.sync.accessibility",
                        "Sync %@ with ArkhamDB",
                        deck.name
                    ))
                    .accessibilityIdentifier(
                        AccountAccessibilityID.deckSyncButton(for: deck.id.rawValue)
                    )
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Delete \(deck.name)", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(deck.name)")
                .accessibilityIdentifier(
                    AccountAccessibilityID.deckDeleteButton(for: deck.id.rawValue)
                )
            }
        }
    }
}

#if DEBUG
    #Preview("Decks") {
        NavigationStack {
            DecksView(model: previewAppModel(), profile: .hosted)
        }
        .background(ArkhamTheme.backgroundGradient)
        .foregroundStyle(ArkhamTheme.bone)
    }
#endif
