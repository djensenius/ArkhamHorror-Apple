// swiftlint:disable file_length
import SwiftUI

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
            if let investigator = localInvestigator {
                CampaignUpgradeDeckSheet(
                    model: model,
                    gameID: gameID,
                    promptIdentity: prompt.identity,
                    investigator: investigator
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
            CampaignBetweenSummaryView(summary: campaignSummary)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let resolution = summary.latestResolution {
                CampaignBetweenSection(
                    title: campaignLocalized("campaign.between.resolution", "Latest resolution")
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(resolution.title)
                            .font(.headline)
                        if let detail = resolution.detail {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityLabel(campaignLocalized(
                    "campaign.between.resolution.accessibility", "Latest resolution"
                ))
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
                .accessibilityLabel(campaignLocalized(
                    "campaign.between.progress.accessibility", "Investigator XP and trauma"
                ))
            }

            if !summary.log.isEmpty {
                CampaignBetweenLogView(log: summary.log)
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
        .accessibilityLabel(String(
            format: campaignLocalized(
                "campaign.between.investigator.accessibility",
                "%@, %d available XP, %d physical trauma, %d mental trauma"
            ),
            investigator.displayName,
            investigator.availableExperience,
            investigator.physicalTrauma,
            investigator.mentalTrauma
        ))
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

    var body: some View {
        CampaignBetweenSection(title: campaignLocalized("campaign.between.log", "Campaign log")) {
            VStack(alignment: .leading, spacing: 10) {
                if !log.entries.isEmpty {
                    CampaignLogList(
                        title: campaignLocalized("campaign.between.log.entries", "Entries"),
                        rows: log.entries.map { entry in
                            CampaignLogRowText(title: entry.title, isCrossedOut: entry.isCrossedOut)
                        }
                    )
                }
                if !log.counts.isEmpty {
                    CampaignLogList(
                        title: campaignLocalized("campaign.between.log.counts", "Counts"),
                        rows: log.counts.map { count in
                            CampaignLogRowText(
                                title: "\(count.title): \(count.value)",
                                isCrossedOut: false
                            )
                        }
                    )
                }
                ForEach(log.recordedSets) { set in
                    CampaignLogList(
                        title: set.title,
                        rows: set.values.map { value in
                            CampaignLogRowText(
                                title: value.isCircled ? "◯ \(value.title)" : value.title,
                                isCrossedOut: value.isCrossedOut
                            )
                        }
                    )
                }
            }
        }
        .accessibilityLabel(campaignLocalized(
            "campaign.between.log.accessibility", "Campaign log"
        ))
    }
}

private struct CampaignLogRowText: Identifiable {
    let id = UUID()
    let title: String
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
            }
        }
    }
}

struct CampaignUpgradeDeckSheet: View {
    let model: AppModel
    let gameID: GameID
    let promptIdentity: BasicChoicePromptIdentity
    let investigator: BoardInvestigatorNode

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
                            Text(campaignLocalized(
                                "campaign.upgrade.submit", "Submit upgrade"
                            ))
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
