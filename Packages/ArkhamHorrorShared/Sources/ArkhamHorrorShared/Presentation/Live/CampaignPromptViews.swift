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

    private var localInvestigator: BoardInvestigatorNode? {
        projection.investigators.first { $0.playerID == prompt.ownerID }
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            ArkhamCard {
                VStack(alignment: .leading, spacing: 16) {
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
                    Text(campaignLocalized(
                        "campaign.between.futureSlot",
                        "Resolution details, campaign log, XP, and trauma will appear here "
                            + "in the next campaign-log update."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if let message = prompt.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(
                                AccountAccessibilityID.campaignPromptFailureText
                            )
                    }

                    if let feedback = prompt.serverFeedback {
                        Label(feedback, systemImage: "exclamationmark.bubble")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("liveGame.prompt.serverFeedback")
                    }

                    HStack(spacing: 12) {
                        if prompt.isAuthorized {
                            if !isUpgradePrompt, let continuation {
                                Button {
                                    sendContinue(step: continuation.nextStep)
                                } label: {
                                    HStack {
                                        Text(campaignLocalized(
                                            "campaign.between.continue", "Continue"
                                        ))
                                        if isSending {
                                            ProgressView().controlSize(.small)
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!prompt.canSubmit)
                                .accessibilityIdentifier(
                                    AccountAccessibilityID.campaignContinueButton
                                )
                            }

                            if isUpgradePrompt {
                                Button {
                                    isUpgradeSheetPresented = true
                                } label: {
                                    Text(campaignLocalized(
                                        "campaign.between.upgradeDeck", "Upgrade deck"
                                    ))
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(localInvestigator == nil || !prompt.canSubmit)
                                .accessibilityIdentifier(
                                    AccountAccessibilityID.campaignUpgradeDeckButton
                                )
                            } else if continuation?.canUpgrade == true, let continuation {
                                Button {
                                    sendContinue(step: continuation.upgradeStep)
                                } label: {
                                    HStack {
                                        Text(campaignLocalized(
                                            "campaign.between.upgradeDeck", "Upgrade deck"
                                        ))
                                        if isSending {
                                            ProgressView().controlSize(.small)
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(!prompt.canSubmit)
                                .accessibilityIdentifier(
                                    AccountAccessibilityID.campaignUpgradeDeckButton
                                )
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
            }
            .frame(maxWidth: 640)
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
                    investigator: investigator
                )
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

struct CampaignUpgradeDeckSheet: View {
    let model: AppModel
    let gameID: GameID
    let investigator: BoardInvestigatorNode

    @Environment(\.dismiss) private var dismiss
    @State private var deckURL = ""
    @State private var isSubmitting = false
    @State private var failure: String?
    @State private var isSkipConfirmationPresented = false

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
                        isSubmitting || deckURL.trimmingCharacters(
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
                    .disabled(isSubmitting)
                    .accessibilityIdentifier(
                        AccountAccessibilityID.campaignUpgradeDeckSkipButton
                    )
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
                }
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
                Button(campaignLocalized("campaign.upgrade.skipConfirmationCancel", "Cancel"), role: .cancel) {}
            } message: {
                Text(campaignLocalized(
                    "campaign.upgrade.skipConfirmationMessage",
                    "You cannot undo this campaign step after it is sent."
                ))
            }
        }
        }
    }

    private func submitUpgrade() {
        Task {
            isSubmitting = true
            failure = nil
            let result = await model.upgradeCampaignDeck(
                from: deckURL,
                investigatorId: investigator.id.rawValue.rawValue,
                in: gameID
            )
            finish(result)
        }
    }

    private func continueWithoutUpgrading() {
        Task {
            isSubmitting = true
            failure = nil
            let result = await model.continueCampaignWithoutUpgrading(
                investigatorId: investigator.id.rawValue.rawValue,
                in: gameID
            )
            finish(result)
        }
    }

    private func finish(_ result: CampaignDeckUpgradeSubmissionResult) {
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
