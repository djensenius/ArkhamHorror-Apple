import SwiftUI

struct CreateGameSheetView: View {
    let model: AppModel
    let onCreated: (GameID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = CreateGameViewModel()

    var body: some View {
        Form {
            gameSection
            playersSection
            nameSection
            if let failure = viewModel.failureMessage {
                Section {
                    ArkhamFailureText(message: failure)
                        .accessibilityLabel("New game error: \(failure)")
                        .accessibilityIdentifier(AccountAccessibilityID.createGameFailureText)
                }
            }
        }
        .navigationTitle("New Game")
        #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .interactiveDismissDisabled(viewModel.isSubmitting)
        .accessibilityIdentifier(AccountAccessibilityID.createGameSheet)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .disabled(viewModel.isSubmitting)
                .accessibilityLabel("Cancel new game")
                .accessibilityIdentifier(AccountAccessibilityID.createGameCancelButton)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await submit() }
                } label: {
                    if viewModel.isSubmitting {
                        ProgressView()
                    } else {
                        Text("Create")
                    }
                }
                .disabled(!viewModel.canSubmit)
                .accessibilityLabel(viewModel.isSubmitting ? "Creating game" : "Create game")
                .accessibilityIdentifier(AccountAccessibilityID.createGameSubmitButton)
            }
        }
    }

    private var gameSection: some View {
        Section("Game") {
            Picker(
                "Mode",
                selection: Binding(
                    get: { viewModel.mode },
                    set: { viewModel.mode = $0 }
                )
            ) {
                ForEach(CreateGameMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityLabel("Game mode")
            .accessibilityIdentifier(AccountAccessibilityID.createGameModePicker)

            switch viewModel.mode {
            case .campaign:
                Picker(
                    "Campaign",
                    selection: Binding(
                        get: { viewModel.selectedCampaignID },
                        set: { viewModel.selectedCampaignID = $0 }
                    )
                ) {
                    ForEach(viewModel.catalog.campaigns) { campaign in
                        Text(campaign.title).tag(campaign.id)
                    }
                }
                .accessibilityLabel("Campaign")
                .accessibilityHint("Choose which campaign to create.")
                .accessibilityIdentifier(AccountAccessibilityID.createGameCatalogPicker)
            case .standaloneScenario:
                Picker(
                    "Scenario",
                    selection: Binding(
                        get: { viewModel.selectedScenarioID },
                        set: { viewModel.selectedScenarioID = $0 }
                    )
                ) {
                    ForEach(viewModel.catalog.standaloneScenarios) { scenario in
                        Text(scenario.title).tag(scenario.id)
                    }
                }
                .accessibilityLabel("Scenario")
                .accessibilityHint("Choose which standalone scenario to create.")
                .accessibilityIdentifier(AccountAccessibilityID.createGameCatalogPicker)
            }

            Picker(
                "Difficulty",
                selection: Binding(
                    get: { viewModel.difficulty },
                    set: { viewModel.difficulty = $0 }
                )
            ) {
                ForEach(RequestDifficulty.allCases, id: \.self) { difficulty in
                    Text(difficulty.displayName).tag(difficulty)
                }
            }
            .accessibilityLabel("Difficulty")
            .accessibilityIdentifier(AccountAccessibilityID.createGameDifficultyPicker)
        }
        .disabled(viewModel.isSubmitting)
    }

    private var playersSection: some View {
        Section("Players") {
            Picker(
                "Player count",
                selection: Binding(
                    get: { viewModel.playerCount },
                    set: { viewModel.playerCount = $0 }
                )
            ) {
                ForEach(1 ... 4, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .accessibilityLabel("Player count")
            .accessibilityValue("\(viewModel.playerCount)")
            .accessibilityIdentifier(AccountAccessibilityID.createGamePlayerCountPicker)

            if viewModel.shouldShowMultiplayerVariant {
                Picker(
                    "Multiplayer",
                    selection: Binding(
                        get: { viewModel.multiplayerVariant },
                        set: { viewModel.multiplayerVariant = $0 }
                    )
                ) {
                    ForEach(viewModel.availableMultiplayerVariants, id: \.self) { variant in
                        Text(variant.displayName).tag(variant)
                    }
                }
                .accessibilityLabel("Multiplayer variant")
                .accessibilityIdentifier(AccountAccessibilityID.createGameVariantPicker)
            }
        }
        .disabled(viewModel.isSubmitting)
    }

    private var nameSection: some View {
        Section {
            TextField(
                viewModel.selectedTitle,
                text: Binding(
                    get: { viewModel.customName },
                    set: { viewModel.customName = $0 }
                )
            )
            .disabled(viewModel.isSubmitting)
            .accessibilityLabel("Game name")
            .accessibilityHint("Optional. Leave blank to use \(viewModel.selectedTitle).")
            .accessibilityIdentifier(AccountAccessibilityID.createGameNameField)
        } header: {
            Text("Name")
        } footer: {
            Text("Leave blank to use \(viewModel.selectedTitle).")
        }
    }

    private func submit() async {
        guard let id = await viewModel.submit(createGame: { request in
            try await model.createGame(request)
        }) else { return }
        onCreated(id)
        dismiss()
    }
}
