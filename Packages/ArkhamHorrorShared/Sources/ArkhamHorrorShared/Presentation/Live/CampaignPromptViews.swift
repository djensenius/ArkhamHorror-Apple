// swiftlint:disable file_length
import SwiftUI

struct CampaignUpgradeDeckContext: Sendable, Equatable {
    let requiresReplacement: Bool
    let killedOrInsaneInvestigatorIDs: Set<String>

    var allowsSkip: Bool {
        !requiresReplacement
    }

    static func make(
        investigator: BoardInvestigatorNode,
        campaignSummary: BoardCampaignSummary?
    ) -> CampaignUpgradeDeckContext {
        let killedOrInsaneIDs = campaignSummary?.killedOrInsaneInvestigatorIDs ?? []
        return CampaignUpgradeDeckContext(
            requiresReplacement: killedOrInsaneIDs.contains(investigator.id.rawValue.rawValue),
            killedOrInsaneInvestigatorIDs: killedOrInsaneIDs
        )
    }
}

struct BetweenScenariosView: View {
    let model: AppModel
    let gameID: GameID
    let projection: BoardProjection
    let prompt: BasicChoicePromptPresentation

    @State private var isUpgradeSheetPresented = false

    private var continuation: CampaignContinuationContext? {
        projection.campaignContinuation
    }

    private var isUpgradePrompt: Bool {
        prompt.isChooseUpgradeDeckPrompt
    }

    private var isSending: Bool {
        prompt.actionPhase == .sending
    }

    private var campaignDeckStatusMessage: String? {
        if model.isCampaignDeckSubmissionAwaitingSnapshot(for: prompt.identity) {
            return campaignDeckSubmissionAwaitingSnapshotMessage()
        }
        return prompt.statusMessage
    }

    private var localInvestigator: BoardInvestigatorNode? {
        projection.investigators.first { $0.playerID == prompt.ownerID }
    }

    private var campaignSummary: BoardCampaignSummary? {
        projection.campaignSummary
    }

    private var campaignSummaryContext: BoardCampaignSummaryDisplayContext {
        BoardCampaignSummaryDisplayContext(
            localeCatalogResolver: model.localeCatalogResolver,
            cardCatalog: model.cardCatalog
        )
    }

    private var deckUpgradeContext: CampaignUpgradeDeckContext? {
        guard let localInvestigator else { return nil }
        return CampaignUpgradeDeckContext.make(
            investigator: localInvestigator,
            campaignSummary: campaignSummary
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            ArkhamCard {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        campaignSummarySection
                        statusSection
                        actionButtons
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 720, maxHeight: 720)
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ArkhamTheme.backgroundGradient.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccountAccessibilityID.campaignBetweenScenariosView)
        .sheet(isPresented: $isUpgradeSheetPresented) {
            if let investigator = localInvestigator, let deckUpgradeContext {
                CampaignUpgradeDeckSheet(
                    model: model,
                    gameID: gameID,
                    promptIdentity: prompt.identity,
                    investigator: investigator,
                    context: deckUpgradeContext
                )
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        Text(campaignLocalized("campaign.between.title", "Between scenarios"))
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(ArkhamTheme.bone)
            .accessibilityAddTraits(.isHeader)
        if let scenarioName = projection.scenario?.displayName {
            Text(String(
                format: campaignLocalized(
                    "campaign.between.finishedScenario", "%@ just finished"
                ),
                scenarioName
            ))
            .font(.headline)
        } else {
            Text(campaignLocalized(
                "campaign.between.noScenario", "No active scenario"
            ))
            .font(.headline)
        }
    }

    @ViewBuilder
    private var campaignSummarySection: some View {
        if let campaignSummary, !campaignSummary.isEmpty {
            CampaignBetweenSummaryView(summary: campaignSummary, context: campaignSummaryContext)
        } else {
            Text(campaignLocalized(
                "campaign.between.emptySummary",
                "The server has not reported campaign-log or XP changes yet."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let message = campaignDeckStatusMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccountAccessibilityID.campaignPromptFailureText)
        }

        if let feedback = prompt.serverFeedback {
            Label(feedback, systemImage: "exclamationmark.bubble")
                .font(.footnote)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("liveGame.prompt.serverFeedback")
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            if isUpgradePrompt {
                if prompt.canUseCampaignDeckPrompt {
                    Button {
                        isUpgradeSheetPresented = true
                    } label: {
                        Text(campaignLocalized("campaign.between.upgradeDeck", "Upgrade deck"))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(localInvestigator == nil)
                    .accessibilityIdentifier(AccountAccessibilityID.campaignUpgradeDeckButton)
                }
            } else if prompt.isAuthorized {
                if let continuation {
                    Button {
                        sendContinue(step: continuation.nextStep)
                    } label: {
                        HStack {
                            Text(campaignLocalized("campaign.between.continue", "Continue"))
                            if isSending {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!prompt.canSubmit)
                    .accessibilityIdentifier(AccountAccessibilityID.campaignContinueButton)
                }

                if continuation?.canUpgrade == true, let continuation {
                    Button {
                        sendContinue(step: continuation.upgradeStep)
                    } label: {
                        HStack {
                            Text(campaignLocalized("campaign.between.upgradeDeck", "Upgrade deck"))
                            if isSending {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!prompt.canSubmit)
                    .accessibilityIdentifier(AccountAccessibilityID.campaignUpgradeDeckButton)
                }
            }

            if prompt.canRetry {
                Button {
                    retryPrompt()
                } label: {
                    Text(campaignLocalized("campaign.between.retry", "Retry"))
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("liveGame.prompt.retry")
            }
        }
    }

    private func sendContinue(step: JSONValue) {
        Task {
            await model.submitContinueCampaignAnswer(prompt.identity, step: step)
        }
    }

    private func retryPrompt() {
        Task {
            await model.retryBasicChoice(prompt.identity)
        }
    }
}

private struct CampaignBetweenSummaryView: View {
    let summary: BoardCampaignSummary
    let context: BoardCampaignSummaryDisplayContext

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !summary.resolutions.isEmpty {
                CampaignBetweenSection(
                    title: campaignLocalized("campaign.between.resolutions", "Scenario resolutions")
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(
                            Array(summary.resolutions.enumerated()), id: \.offset
                        ) { _, resolution in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(resolution.title(context: context))
                                    .font(.headline)
                                if let detail = resolution.detail(context: context) {
                                    Text(detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }

            if !summary.investigators.isEmpty {
                CampaignBetweenSection(
                    title: campaignLocalized("campaign.between.progress", "Investigator progress")
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(summary.investigators) { investigator in
                            CampaignInvestigatorProgressRow(investigator: investigator)
                        }
                    }
                }
            }

            if !summary.log.isEmpty {
                CampaignBetweenLogView(log: summary.log, context: context)
            }
        }
    }
}

private struct CampaignBetweenSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(ArkhamTheme.bone)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CampaignInvestigatorProgressRow: View {
    let investigator: BoardCampaignInvestigatorProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(investigator.displayName)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                CampaignPill(text: String(
                    format: campaignLocalized("campaign.between.availableXp", "%d XP available"),
                    investigator.availableExperience
                ))
                CampaignPill(text: String(
                    format: campaignLocalized("campaign.between.totalXp", "%d total / %d spent"),
                    investigator.experiencePoints,
                    investigator.spentExperience
                ))
            }
            HStack(spacing: 8) {
                CampaignPill(text: String(
                    format: campaignLocalized(
                        "campaign.between.physicalTrauma", "%d physical trauma"
                    ),
                    investigator.physicalTrauma
                ))
                CampaignPill(text: String(
                    format: campaignLocalized(
                        "campaign.between.mentalTrauma", "%d mental trauma"
                    ),
                    investigator.mentalTrauma
                ))
                if investigator.killed {
                    CampaignPill(text: campaignLocalized("campaign.between.killed", "Killed"))
                }
                if investigator.drivenInsane {
                    CampaignPill(text: campaignLocalized(
                        "campaign.between.drivenInsane", "Driven insane"
                    ))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CampaignPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ArkhamTheme.bone.opacity(0.14), in: Capsule())
    }
}

private struct CampaignBetweenLogView: View {
    let log: BoardCampaignLogSummary
    let context: BoardCampaignSummaryDisplayContext

    var body: some View {
        CampaignBetweenSection(title: campaignLocalized("campaign.between.log", "Campaign log")) {
            VStack(alignment: .leading, spacing: 10) {
                if !log.entries.isEmpty {
                    CampaignLogList(
                        title: campaignLocalized("campaign.between.log.entries", "Entries"),
                        rows: log.entries.map { entry in
                            let title = entry.title(context: context)
                            return CampaignLogRowText(
                                id: entry.id,
                                title: title,
                                accessibilityTitle: entry.accessibilityTitle(context: context),
                                isCrossedOut: entry.isCrossedOut
                            )
                        }
                    )
                }
                if !log.counts.isEmpty {
                    CampaignLogList(
                        title: campaignLocalized("campaign.between.log.counts", "Counts"),
                        rows: log.counts.map { count in
                            let title = "\(count.title(context: context)): \(count.value)"
                            return CampaignLogRowText(
                                id: count.id,
                                title: title,
                                accessibilityTitle: title,
                                isCrossedOut: false
                            )
                        }
                    )
                }
                ForEach(log.recordedSets) { set in
                    CampaignLogList(
                        title: set.title(context: context),
                        rows: set.values.map { value in
                            let title = value.title(context: context)
                            return CampaignLogRowText(
                                id: value.id,
                                title: value.isCircled ? "◯ \(title)" : title,
                                accessibilityTitle: recordedValueAccessibilityLabel(
                                    title, value: value
                                ),
                                isCrossedOut: value.isCrossedOut
                            )
                        }
                    )
                }
            }
        }
    }

    private func recordedValueAccessibilityLabel(
        _ title: String,
        value: BoardCampaignLogRecordedValue
    ) -> String {
        switch (value.isCrossedOut, value.isCircled) {
        case (true, true):
            String(format: campaignLocalized(
                "campaign.between.log.value.crossedOutCircled.accessibility",
                "%@, crossed out, circled"
            ), title)
        case (true, false):
            String(format: campaignLocalized(
                "campaign.between.log.value.crossedOut.accessibility",
                "%@, crossed out"
            ), title)
        case (false, true):
            String(format: campaignLocalized(
                "campaign.between.log.value.circled.accessibility",
                "%@, circled"
            ), title)
        case (false, false):
            title
        }
    }
}

private struct CampaignLogRowText: Identifiable {
    let id: String
    let title: String
    let accessibilityTitle: String
    let isCrossedOut: Bool
}

private struct CampaignLogList: View {
    let title: String
    let rows: [CampaignLogRowText]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("–")
                        .foregroundStyle(.secondary)
                    Text(row.title)
                        .strikethrough(row.isCrossedOut)
                        .foregroundStyle(row.isCrossedOut ? .secondary : .primary)
                }
                .font(.footnote)
                .accessibilityLabel(row.accessibilityTitle)
            }
        }
    }
}

struct CampaignUpgradeDeckSheet: View {
    let model: AppModel
    let gameID: GameID
    let promptIdentity: BasicChoicePromptIdentity
    let investigator: BoardInvestigatorNode
    let context: CampaignUpgradeDeckContext

    @Environment(\.dismiss) private var dismiss
    @State private var deckURL = ""
    @State private var isSubmitting = false
    @State private var failure: String?
    @State private var isSkipConfirmationPresented = false
    @State private var submissionTask: Task<Void, Never>?

    private var isAwaitingSnapshot: Bool {
        model.isCampaignDeckSubmissionAwaitingSnapshot(for: promptIdentity)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(
                        campaignLocalized("campaign.upgrade.investigator", "Investigator"),
                        value: investigator.displayName
                    )
                    LabeledContent(
                        campaignLocalized("campaign.upgrade.availableXp", "Available XP"),
                        value: "\(investigator.availableExperience)"
                    )
                    LabeledContent(
                        campaignLocalized("campaign.upgrade.totalXp", "Total / spent XP"),
                        value: "\(investigator.experiencePoints) / \(investigator.spentExperience)"
                    )
                    LabeledContent(
                        campaignLocalized("campaign.upgrade.trauma", "Trauma"),
                        value: String(
                            format: campaignLocalized(
                                "campaign.upgrade.traumaValue", "%d physical / %d mental"
                            ),
                            investigator.physicalTrauma,
                            investigator.mentalTrauma
                        )
                    )
                }
                if context.requiresReplacement {
                    Section {
                        Text(campaignLocalized(
                            "campaign.upgrade.replacementRequired",
                            "This investigator was killed or driven insane. Choose a replacement "
                                + "investigator deck to continue."
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                savedDeckSection

                Section(campaignLocalized("campaign.upgrade.deckLink", "Deck link")) {
                    TextField(
                        campaignLocalized(
                            "campaign.upgrade.deckPlaceholder",
                            "ArkhamDB or arkham.build deck link"
                        ),
                        text: $deckURL
                    )
                    #if os(iOS) || os(visionOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .accessibilityIdentifier(
                        AccountAccessibilityID.campaignUpgradeDeckURLField
                    )

                    Button {
                        submitUpgrade()
                    } label: {
                        HStack {
                            Text(context.requiresReplacement
                                ? campaignLocalized(
                                    "campaign.upgrade.submitReplacement", "Submit replacement"
                                )
                                : campaignLocalized(
                                    "campaign.upgrade.submit", "Submit upgrade"
                                )
                            )
                            if isSubmitting {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(
                        isSubmitting || isAwaitingSnapshot || deckURL.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )
                    .accessibilityIdentifier(
                        AccountAccessibilityID.campaignUpgradeDeckSubmitButton
                    )
                }

                if context.allowsSkip {
                    Section {
                        Button(role: .cancel) {
                            isSkipConfirmationPresented = true
                        } label: {
                            HStack {
                                Text(campaignLocalized(
                                    "campaign.upgrade.skip", "Continue without upgrading"
                                ))
                                if isSubmitting {
                                    Spacer()
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        .disabled(isSubmitting || isAwaitingSnapshot)
                        .accessibilityIdentifier(
                            AccountAccessibilityID.campaignUpgradeDeckSkipButton
                        )
                    }
                }

                if isAwaitingSnapshot {
                    Section {
                        Text(campaignDeckSubmissionAwaitingSnapshotMessage())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(
                                AccountAccessibilityID.campaignPromptFailureText
                            )
                    }
                }

                if let failure {
                    Section {
                        ArkhamFailureText(message: failure)
                            .accessibilityIdentifier(
                                AccountAccessibilityID.campaignPromptFailureText
                            )
                    }
                }
            }
            .navigationTitle(campaignLocalized("campaign.upgrade.title", "Upgrade deck"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(campaignLocalized("campaign.upgrade.done", "Done")) {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .onDisappear {
                submissionTask?.cancel()
                submissionTask = nil
            }
            .confirmationDialog(
                campaignLocalized(
                    "campaign.upgrade.skipConfirmationTitle",
                    "Continue without upgrading?"
                ),
                isPresented: $isSkipConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button(
                    campaignLocalized(
                        "campaign.upgrade.skipConfirmationConfirm",
                        "Continue without upgrading"
                    ),
                    role: .destructive
                ) {
                    continueWithoutUpgrading()
                }
                Button(
                    campaignLocalized("campaign.upgrade.skipConfirmationCancel", "Cancel"),
                    role: .cancel
                ) {}
            } message: {
                Text(campaignLocalized(
                    "campaign.upgrade.skipConfirmationMessage",
                    "You cannot undo this campaign step after it is sent."
                ))
            }
        }
    }

    @ViewBuilder
    private var savedDeckSection: some View {
        if case let .signedIn(profile, _, _) = model.sessionState {
            CampaignSavedDeckSelectionSection(
                model: model,
                profile: profile,
                gameID: gameID,
                promptIdentity: promptIdentity,
                investigator: investigator,
                isSubmitting: isSubmitting,
                isAwaitingSnapshot: isAwaitingSnapshot,
                onBeginSubmit: beginSavedDeckSubmission,
                onFinishSubmit: finish
            )
        }
    }

    private func beginSavedDeckSubmission() -> Bool {
        guard !isSubmitting, !isAwaitingSnapshot else { return false }
        submissionTask?.cancel()
        isSubmitting = true
        failure = nil
        return true
    }

    private func submitUpgrade() {
        guard !isAwaitingSnapshot else { return }
        submissionTask?.cancel()
        submissionTask = Task { @MainActor in
            isSubmitting = true
            failure = nil
            let result = await model.upgradeCampaignDeck(
                from: deckURL,
                investigatorId: investigator.id.rawValue.rawValue,
                in: gameID,
                promptIdentity: promptIdentity
            )
            guard !Task.isCancelled else { return }
            finish(result)
        }
    }

    private func continueWithoutUpgrading() {
        guard !isAwaitingSnapshot else { return }
        submissionTask?.cancel()
        submissionTask = Task { @MainActor in
            isSubmitting = true
            failure = nil
            let result = await model.continueCampaignWithoutUpgrading(
                investigatorId: investigator.id.rawValue.rawValue,
                in: gameID,
                promptIdentity: promptIdentity
            )
            guard !Task.isCancelled else { return }
            finish(result)
        }
    }

    private func finish(_ result: CampaignDeckUpgradeSubmissionResult) {
        submissionTask = nil
        isSubmitting = false
        switch result {
        case .submitted:
            dismiss()
        case let .failed(message):
            failure = message
        }
    }
}

private struct CampaignSavedDeckSelectionSection: View {
    let model: AppModel
    let profile: ServerProfile
    let gameID: GameID
    let promptIdentity: BasicChoicePromptIdentity
    let investigator: BoardInvestigatorNode
    let isSubmitting: Bool
    let isAwaitingSnapshot: Bool
    let onBeginSubmit: () -> Bool
    let onFinishSubmit: (CampaignDeckUpgradeSubmissionResult) -> Void

    @State private var viewModel: LobbyDeckSelectionViewModel

    init(
        model: AppModel,
        profile: ServerProfile,
        gameID: GameID,
        promptIdentity: BasicChoicePromptIdentity,
        investigator: BoardInvestigatorNode,
        isSubmitting: Bool,
        isAwaitingSnapshot: Bool,
        onBeginSubmit: @escaping () -> Bool,
        onFinishSubmit: @escaping (CampaignDeckUpgradeSubmissionResult) -> Void
    ) {
        self.model = model
        self.profile = profile
        self.gameID = gameID
        self.promptIdentity = promptIdentity
        self.investigator = investigator
        self.isSubmitting = isSubmitting
        self.isAwaitingSnapshot = isAwaitingSnapshot
        self.onBeginSubmit = onBeginSubmit
        self.onFinishSubmit = onFinishSubmit
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
        Section(campaignLocalized("campaign.upgrade.savedDecks", "Saved decks")) {
            switch viewModel.loadState {
            case .idle, .loading:
                HStack {
                    Text(campaignLocalized("campaign.upgrade.loadingDecks", "Loading saved decks…"))
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            case let .failed(message):
                ArkhamFailureText(message: message)
                Button(campaignLocalized("campaign.upgrade.retryDecks", "Retry saved decks")) {
                    Task { await viewModel.reload() }
                }
            case let .loaded(decks):
                if decks.isEmpty {
                    Text(campaignLocalized(
                        "campaign.upgrade.noSavedDecks",
                        "No saved decks are available."
                    ))
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(decks, id: \.id) { deck in
                        deckButton(deck)
                    }
                }
            }
        }
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private func deckButton(_ deck: Deck) -> some View {
        let state = viewModel.validationState(for: deck)
        Button {
            submit(deck)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(ArkhamTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(deck.name)
                        .font(.headline)
                    Text(deck.investigatorName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    validationText(for: state, deck: deck)
                }
                Spacer()
                if isSubmitting || state == .pending {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(isSubmitting || isAwaitingSnapshot || state != .valid)
        .accessibilityIdentifier(AccountAccessibilityID.lobbyDeckButton(
            for: gameID.rawValue,
            deckID: deck.id.rawValue
        ))
    }

    @ViewBuilder
    private func validationText(
        for state: LobbyDeckSelectionViewModel.ValidationState,
        deck: Deck
    ) -> some View {
        switch state {
        case .pending:
            Text(campaignLocalized("campaign.upgrade.checkingDeck", "Checking server support…"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .valid:
            Text(campaignLocalized(
                "campaign.upgrade.validDeck", "Server can play this deck's main cards."
            ))
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

    private func submit(_ deck: Deck) {
        guard onBeginSubmit() else { return }
        Task { @MainActor in
            let result = await model.upgradeCampaignDeck(
                using: deck,
                investigatorId: investigator.id.rawValue.rawValue,
                in: gameID,
                promptIdentity: promptIdentity
            )
            guard !Task.isCancelled else { return }
            onFinishSubmit(result)
        }
    }
}

extension BasicChoicePromptPresentation {
    var isChooseUpgradeDeckPrompt: Bool {
        identity.rawQuestion.hasQuestionTag("ChooseUpgradeDeck")
            || identity.rawQuestion.wrapsQuestionTag("QuestionLabel", innerTag: "ChooseUpgradeDeck")
            || semanticPresentation?.presentation.questionKind == .chooseUpgradeDeck
    }

    var canUseCampaignDeckPrompt: Bool {
        guard isChooseUpgradeDeckPrompt else { return false }
        switch readOnlyReason {
        case nil, .updateRequired:
            return true
        case .spectator, .anotherPlayer, .legacyServer, .disconnected:
            return false
        }
    }
}

private extension JSONValue {
    func hasQuestionTag(_ expected: String) -> Bool {
        guard case let .object(object) = self,
              object["tag"] == .string(expected)
        else { return false }
        return true
    }

    func wrapsQuestionTag(_ expected: String, innerTag: String) -> Bool {
        guard case let .object(object) = self,
              object["tag"] == .string(expected),
              let inner = object["question"]
        else { return false }
        return inner.hasQuestionTag(innerTag)
    }
}

private func campaignLocalized(_ key: String, _ fallback: String) -> String {
    NSLocalizedString(key, bundle: .module, value: fallback, comment: "")
}
