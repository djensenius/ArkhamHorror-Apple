import SwiftUI

// swiftlint:disable:next type_body_length
struct CreateGameSheetView: View {
    let model: AppModel
    let onCreated: (GameID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = CreateGameViewModel(isCatalogLoading: true)
    @State private var didLoadCatalog = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
    }

    var body: some View {
        Form {
            if let warning = viewModel.catalogWarningMessage {
                Section {
                    ArkhamFailureText(message: warning)
                        .accessibilityLabel(gameLifecycleLocalizedFormat(
                            "create.catalog.warning.accessibility",
                            "Campaign catalog warning: %@",
                            warning
                        ))
                        .accessibilityIdentifier(AccountAccessibilityID.createGameCatalogWarningText) // swiftlint:disable:this line_length
                }
            }
            gameSection
            optionsSection
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
        .navigationTitle(gameLifecycleLocalized("create.title", "New Game"))
        #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 620)
        #endif
        .interactiveDismissDisabled(viewModel.isSubmitting)
        .accessibilityIdentifier(AccountAccessibilityID.createGameSheet)
        .task { await loadCatalogIfNeeded() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(gameLifecycleLocalized("create.cancel", "Cancel")) {
                    dismiss()
                }
                .disabled(viewModel.isSubmitting)
                .accessibilityLabel(gameLifecycleLocalized("create.cancel.accessibility", "Cancel new game")) // swiftlint:disable:this line_length
                .accessibilityIdentifier(AccountAccessibilityID.createGameCancelButton)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await submit() }
                } label: {
                    if viewModel.isSubmitting {
                        ProgressView()
                    } else {
                        Text(gameLifecycleLocalized("create.submit", "Create"))
                    }
                }
                .disabled(!viewModel.canSubmit)
                .accessibilityLabel(viewModel.isSubmitting
                    ? gameLifecycleLocalized("create.submitting.accessibility", "Creating game")
                    : gameLifecycleLocalized("create.submit.accessibility", "Create game"))
                .accessibilityIdentifier(AccountAccessibilityID.createGameSubmitButton)
            }
        }
    }

    private var gameSection: some View {
        Section(gameLifecycleLocalized("create.section.game", "Game")) {
            Picker(
                gameLifecycleLocalized("create.mode", "Mode"),
                selection: Binding(get: { viewModel.mode }, set: { viewModel.mode = $0 })
            ) {
                ForEach(CreateGameMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityLabel(gameLifecycleLocalized("create.mode.accessibility", "Game mode"))
            .accessibilityIdentifier(AccountAccessibilityID.createGameModePicker)

            switch viewModel.mode {
            case .campaign:
                Picker(
                    gameLifecycleLocalized("create.campaign", "Campaign"),
                    selection: Binding(
                        get: { viewModel.selectedCampaignID },
                        set: { viewModel.selectedCampaignID = $0 }
                    )
                ) {
                    ForEach(viewModel.catalog.campaigns) { campaign in
                        Text(releaseLabel(campaign.title, alpha: campaign.alpha, beta: campaign.beta)) // swiftlint:disable:this line_length
                            .tag(campaign.id)
                    }
                }
                .accessibilityLabel(gameLifecycleLocalized("create.campaign.accessibility", "Campaign")) // swiftlint:disable:this line_length
                .accessibilityHint(
                    gameLifecycleLocalized("create.campaign.hint", "Choose which campaign to create.") // swiftlint:disable:this line_length
                )
                .accessibilityIdentifier(AccountAccessibilityID.createGameCatalogPicker)
            case .standaloneScenario:
                Picker(
                    gameLifecycleLocalized("create.scenario", "Scenario"),
                    selection: Binding(
                        get: { viewModel.selectedScenarioID },
                        set: { viewModel.selectedScenarioID = $0 }
                    )
                ) {
                    ForEach(viewModel.catalog.standaloneScenarios) { scenario in
                        Text(releaseLabel(scenario.title, alpha: scenario.alpha, beta: scenario.beta)) // swiftlint:disable:this line_length
                            .tag(scenario.id)
                    }
                }
                .accessibilityLabel(gameLifecycleLocalized("create.scenario.accessibility", "Scenario")) // swiftlint:disable:this line_length
                .accessibilityHint(
                    gameLifecycleLocalized("create.scenario.hint", "Choose which standalone scenario or side story to create.") // swiftlint:disable:this line_length
                )
                .accessibilityIdentifier(AccountAccessibilityID.createGameCatalogPicker)
            }

            if !viewModel.selectedSideStoryParts.isEmpty {
                Picker(
                    gameLifecycleLocalized("create.sideStoryMode", "Scenarios"),
                    selection: Binding(
                        get: { viewModel.selectedSideStoryPartID },
                        set: { viewModel.selectedSideStoryPartID = $0 }
                    )
                ) {
                    Text(gameLifecycleLocalized("create.bothScenarios", "Both scenarios"))
                        .tag(String?.none)
                    ForEach(viewModel.selectedSideStoryParts) { part in
                        Text(part.title).tag(Optional(part.id))
                    }
                }
                .accessibilityLabel(
                    gameLifecycleLocalized("create.sideStoryMode.accessibility", "Side-story scenario selection") // swiftlint:disable:this line_length
                )
                .accessibilityIdentifier(AccountAccessibilityID.createGameSideStoryModePicker)
            }

            if viewModel.canToggleReturnTo {
                Toggle(
                    returnToLabel,
                    isOn: Binding(get: { viewModel.useReturnTo }, set: { viewModel.useReturnTo = $0 }) // swiftlint:disable:this line_length
                )
                .accessibilityIdentifier(AccountAccessibilityID.createGameReturnToToggle)
            }

            if let required = viewModel.selectedScenarioRequiredInvestigatorText {
                Text(required)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        AccountAccessibilityID.createGameRequiredInvestigatorText
                    )
            }

            ForEach(viewModel.selectedScenarioDeckRequirements, id: \.self) { requirement in
                Text(requirement)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccountAccessibilityID.createGameDeckRequirementText)
            }

            if let badge = viewModel.selectionBadge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(badge)
            }

            if !viewModel.availableDifficulties.isEmpty {
                Picker(
                    gameLifecycleLocalized("create.difficulty", "Difficulty"),
                    selection: Binding(get: { viewModel.difficulty }, set: { viewModel.difficulty = $0 }) // swiftlint:disable:this line_length
                ) {
                    ForEach(viewModel.availableDifficulties, id: \.self) { difficulty in
                        Text(difficulty.displayName).tag(difficulty)
                    }
                }
                .accessibilityLabel(gameLifecycleLocalized("create.difficulty.accessibility", "Difficulty")) // swiftlint:disable:this line_length
                .accessibilityIdentifier(AccountAccessibilityID.createGameDifficultyPicker)
            }
        }
        .disabled(viewModel.isSubmitting)
    }

    @ViewBuilder
    private var optionsSection: some View {
        let hasOptions = (
            viewModel.mode == .campaign && !viewModel.selectedCampaignVariants.isEmpty
        ) || !viewModel.selectedRecommendedOptions.isEmpty
        if hasOptions {
            Section(gameLifecycleLocalized("create.section.options", "Options")) {
                if viewModel.mode == .campaign, !viewModel.selectedCampaignVariants.isEmpty {
                    Picker(
                        gameLifecycleLocalized("create.variant", "Variant"),
                        selection: Binding(
                            get: { viewModel.selectedVariantID ?? viewModel.selectedCampaignVariants.first?.id ?? "" }, // swiftlint:disable:this line_length
                            set: { viewModel.selectedVariantID = $0 }
                        )
                    ) {
                        ForEach(viewModel.selectedCampaignVariants) { variant in
                            Text(variant.label).tag(variant.id)
                        }
                    }
                    .accessibilityIdentifier(AccountAccessibilityID.createGameVariantOptionPicker)
                }
                ForEach(viewModel.selectedRecommendedOptions) { option in
                    Toggle(
                        option.label,
                        isOn: Binding(
                            get: { viewModel.isRecommendedOptionEnabled(option) },
                            set: { viewModel.setRecommendedOption(option, enabled: $0) }
                        )
                    )
                    .accessibilityIdentifier(AccountAccessibilityID.createGameRecommendedOptionToggle(option.id)) // swiftlint:disable:this line_length
                }
            }
            .disabled(viewModel.isSubmitting)
        }
    }

    private var playersSection: some View {
        Section(gameLifecycleLocalized("create.section.players", "Players")) {
            Picker(
                gameLifecycleLocalized("create.playerCount", "Player count"),
                selection: Binding(get: { viewModel.playerCount }, set: { viewModel.playerCount = $0 }) // swiftlint:disable:this line_length
            ) {
                ForEach(1 ... 4, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .accessibilityLabel(gameLifecycleLocalized("create.playerCount.accessibility", "Player count")) // swiftlint:disable:this line_length
            .accessibilityValue("\(viewModel.playerCount)")
            .accessibilityIdentifier(AccountAccessibilityID.createGamePlayerCountPicker)

            if viewModel.shouldShowMultiplayerVariant {
                Picker(
                    gameLifecycleLocalized("create.multiplayer", "Multiplayer"),
                    selection: Binding(
                        get: { viewModel.multiplayerVariant },
                        set: { viewModel.multiplayerVariant = $0 }
                    )
                ) {
                    ForEach(viewModel.availableMultiplayerVariants, id: \.self) { variant in
                        Text(variant.displayName).tag(variant)
                    }
                }
                .accessibilityLabel(
                    gameLifecycleLocalized("create.multiplayer.accessibility", "Multiplayer variant") // swiftlint:disable:this line_length
                )
                .accessibilityIdentifier(AccountAccessibilityID.createGameVariantPicker)
            }

            Toggle(
                gameLifecycleLocalized("create.includeTarotReadings", "Include tarot readings"),
                isOn: Binding(
                    get: { viewModel.includeTarotReadings },
                    set: { viewModel.includeTarotReadings = $0 }
                )
            )
            .accessibilityIdentifier(AccountAccessibilityID.createGameTarotToggle)
        }
        .disabled(viewModel.isSubmitting)
    }

    private var returnToLabel: String {
        if viewModel.selectedScenarioUsesBlobReturnToVariant {
            return gameLifecycleLocalized(
                "create.blobElse.toggle", "The Blob That Ate Everything ELSE!"
            )
        }
        return gameLifecycleLocalized("create.returnTo", "Return to")
    }

    private var nameSection: some View {
        Section {
            TextField(
                viewModel.selectedTitle,
                text: Binding(get: { viewModel.customName }, set: { viewModel.customName = $0 })
            )
            .focused($focusedField, equals: .name)
            .disabled(viewModel.isSubmitting)
            .accessibilityLabel(gameLifecycleLocalized("create.name.accessibility", "Game name"))
            .accessibilityHint(
                gameLifecycleLocalizedFormat(
                    "create.name.hint", "Optional. Leave blank to use %@.", viewModel.selectedTitle
                )
            )
            .accessibilityIdentifier(AccountAccessibilityID.createGameNameField)
        } header: {
            Text(gameLifecycleLocalized("create.section.name", "Name"))
        } footer: {
            if viewModel.requiresCustomName {
                Text(gameLifecycleLocalized(
                    "create.name.requiresCustom",
                    "Enter a custom name because localized catalog names are unavailable."
                ))
            } else {
                Text(gameLifecycleLocalizedFormat(
                    "create.name.footer", "Leave blank to use %@.", viewModel.selectedTitle
                ))
            }
        }
    }

    private func releaseLabel(_ title: String, alpha: Bool, beta: Bool) -> String {
        if beta {
            return "\(title) (\(gameLifecycleLocalized("create.release.beta", "Beta")))"
        }
        if alpha {
            return "\(title) (\(gameLifecycleLocalized("create.release.alpha", "Alpha")))"
        }
        return title
    }

    private func loadCatalogIfNeeded() async {
        guard !didLoadCatalog else { return }
        didLoadCatalog = true
        viewModel.setCatalogLoading(true)
        let result = await model.createGameCatalogForSheet()
        viewModel.replaceCatalog(result.catalog, warningMessage: result.warningMessage)
        viewModel.setCatalogLoading(false)
    }

    private func submit() async {
        guard let id = await viewModel.submit(createGame: { request in
            try await model.createGame(request)
        }) else { return }
        onCreated(id)
        dismiss()
    }
}
