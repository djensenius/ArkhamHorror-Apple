import SwiftUI

struct BetweenScenariosView: View {
    let model: AppModel
    let gameID: GameID
    let projection: BoardProjection
    let prompt: BasicChoicePromptPresentation

    @State private var isUpgradeSheetPresented = false
    @State private var actionFailure: String?
    @State private var isSendingContinue = false
    @State private var isSendingUpgradeStep = false

    private var continuation: CampaignContinuationContext? {
        projection.campaignContinuation
    }

    private var isUpgradePrompt: Bool {
        prompt.identity.rawQuestion == .object(["tag": .string("ChooseUpgradeDeck")])
            || prompt.semanticPresentation?.presentation.questionKind == .chooseUpgradeDeck
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

                    if let actionFailure {
                        ArkhamFailureText(message: actionFailure)
                            .accessibilityIdentifier(
                                AccountAccessibilityID.campaignPromptFailureText
                            )
                    }

                    HStack(spacing: 12) {
                        if !isUpgradePrompt, let continuation {
                            Button {
                                sendContinue(step: continuation.nextStep)
                            } label: {
                                HStack {
                                    Text(campaignLocalized(
                                        "campaign.between.continue", "Continue"
                                    ))
                                    if isSendingContinue {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSendingContinue || isSendingUpgradeStep)
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
                            .disabled(localInvestigator == nil)
                            .accessibilityIdentifier(
                                AccountAccessibilityID.campaignUpgradeDeckButton
                            )
                        } else if continuation?.canUpgradeDecks == true, let continuation {
                            Button {
                                sendContinue(
                                    step: continuation.upgradeStep,
                                    isUpgradeStep: true
                                )
                            } label: {
                                HStack {
                                    Text(campaignLocalized(
                                        "campaign.between.upgradeDeck", "Upgrade deck"
                                    ))
                                    if isSendingUpgradeStep {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSendingContinue || isSendingUpgradeStep)
                            .accessibilityIdentifier(
                                AccountAccessibilityID.campaignUpgradeDeckButton
                            )
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

    private func sendContinue(step: JSONValue, isUpgradeStep: Bool = false) {
        Task {
            actionFailure = nil
            if isUpgradeStep {
                isSendingUpgradeStep = true
            } else {
                isSendingContinue = true
            }
            let result = await model.submitContinueCampaignAnswer(
                prompt.identity,
                step: step
            )
            if result != .sentAwaitingSnapshot {
                actionFailure = campaignLocalized(
                    "campaign.between.sendFailed",
                    "That campaign answer could not be sent. Reconnect and try again."
                )
            }
            isSendingContinue = false
            isSendingUpgradeStep = false
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
                        continueWithoutUpgrading()
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

private func campaignLocalized(_ key: String, _ fallback: String) -> String {
    NSLocalizedString(key, bundle: .module, value: fallback, comment: "")
}
