import Foundation

enum CampaignDeckUpgradeSubmissionResult: Sendable, Equatable {
    case submitted
    case failed(String)

    var failureMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}

private struct CampaignDeckSubmissionContext: Sendable {
    let profile: ServerProfile
    let deckContext: DeckRequestContext
    let promptIdentity: BasicChoicePromptIdentity
}

extension AppModel {
    /// Fetches an ArkhamDB/arkham.build deck list with the same guarded import path used
    /// by the Decks screen, then submits it to the backend campaign deck endpoint. The
    /// server remains the deck-validation authority; this path only normalizes the source
    /// URL enough to ask the backend to fetch it.
    func upgradeCampaignDeck(
        from rawURL: String,
        investigatorId rawInvestigatorId: String,
        in gameID: GameID,
        promptIdentity: BasicChoicePromptIdentity
    ) async -> CampaignDeckUpgradeSubmissionResult {
        let profile: ServerProfile
        guard case let .signedIn(signedInProfile, _, _) = sessionState else {
            return .failed(campaignPromptLocalized(
                "campaign.error.signInUpgrade",
                "Sign in again to upgrade this deck."
            ))
        }
        profile = signedInProfile

        guard let investigatorId = try? InvestigatorCode(rawInvestigatorId) else {
            return .failed(campaignPromptLocalized(
                "campaign.error.invalidInvestigator",
                "This investigator could not be sent safely."
            ))
        }
        if let failure = beginCampaignDeckSubmission(
            promptIdentity: promptIdentity,
            investigatorId: investigatorId,
            in: gameID
        ) {
            return failure
        }
        defer { finishCampaignDeckSubmission(promptIdentity: promptIdentity) }

        let fetchURL: String
        do {
            fetchURL = try DeckImportURL.parse(rawURL).fetchURL
        } catch {
            return .failed(campaignPromptLocalized(
                "campaign.error.invalidDeckLink",
                "Enter an https ArkhamDB deck/decklist URL or arkham.build deck/share URL."
            ))
        }

        let context: DeckRequestContext
        do {
            context = try await currentDeckRequestContext(for: profile)
        } catch {
            return .failed(campaignPromptLocalized(
                "campaign.error.sessionExpiredDecks",
                "Your session expired. Sign in again to manage decks."
            ))
        }

        let deckList: DeckList
        do {
            deckList = try await deckService.fetchDeckList(
                FetchDeckRequest(url: fetchURL), on: profile, token: context.token
            )
        } catch let error as DeckServiceError {
            if case .sessionExpired = error {
                await handleDeckSessionExpired(profile: profile, context: context)
            }
            return .failed(campaignDeckFetchFailureMessage(error))
        } catch {
            return .failed(campaignPromptLocalized(
                "campaign.error.fetchDeckFailed",
                "The server could not fetch that deck. Try again."
            ))
        }

        return await submitCampaignDeck(
            deckURL: fetchURL,
            deckList: DeckListInput(deckList, urlOverride: fetchURL),
            investigatorId: investigatorId,
            gameID: gameID,
            context: CampaignDeckSubmissionContext(
                profile: profile,
                deckContext: context,
                promptIdentity: promptIdentity
            )
        )
    }

    func continueCampaignWithoutUpgrading(
        investigatorId rawInvestigatorId: String,
        in gameID: GameID,
        promptIdentity: BasicChoicePromptIdentity
    ) async -> CampaignDeckUpgradeSubmissionResult {
        let profile: ServerProfile
        guard case let .signedIn(signedInProfile, _, _) = sessionState else {
            return .failed(campaignPromptLocalized(
                "campaign.error.signInContinue",
                "Sign in again to continue this campaign."
            ))
        }
        profile = signedInProfile

        guard let investigatorId = try? InvestigatorCode(rawInvestigatorId) else {
            return .failed(campaignPromptLocalized(
                "campaign.error.invalidInvestigator",
                "This investigator could not be sent safely."
            ))
        }
        if let failure = beginCampaignDeckSubmission(
            promptIdentity: promptIdentity,
            investigatorId: investigatorId,
            in: gameID
        ) {
            return failure
        }
        defer { finishCampaignDeckSubmission(promptIdentity: promptIdentity) }

        let context: DeckRequestContext
        do {
            context = try await currentDeckRequestContext(for: profile)
        } catch {
            return .failed(campaignPromptLocalized(
                "campaign.error.sessionExpiredDecks",
                "Your session expired. Sign in again to manage decks."
            ))
        }

        return await submitCampaignDeck(
            deckURL: nil,
            deckList: nil,
            investigatorId: investigatorId,
            gameID: gameID,
            context: CampaignDeckSubmissionContext(
                profile: profile,
                deckContext: context,
                promptIdentity: promptIdentity
            )
        )
    }

    private func beginCampaignDeckSubmission(
        promptIdentity: BasicChoicePromptIdentity,
        investigatorId: InvestigatorCode,
        in gameID: GameID
    ) -> CampaignDeckUpgradeSubmissionResult? {
        if let failure = validateCampaignDeckPrompt(
            promptIdentity: promptIdentity,
            investigatorId: investigatorId,
            in: gameID
        ) {
            return failure
        }
        guard !campaignDeckSubmissionGameIDs.contains(gameID) else {
            return .failed(campaignPromptLocalized(
                "campaign.error.deckSubmissionInFlight",
                "A deck update is already being submitted."
            ))
        }
        campaignDeckSubmissionGameIDs.insert(gameID)
        return nil
    }

    private func finishCampaignDeckSubmission(promptIdentity: BasicChoicePromptIdentity) {
        campaignDeckSubmissionGameIDs.remove(promptIdentity.gameID)
    }

    private func validateCampaignDeckPrompt(
        promptIdentity: BasicChoicePromptIdentity,
        investigatorId: InvestigatorCode,
        in gameID: GameID
    ) -> CampaignDeckUpgradeSubmissionResult? {
        guard case let .participant(playerID) = liveGameParticipantIdentities[gameID],
              playerID == promptIdentity.ownerID,
              let prompt = basicChoicePresentation(for: gameID),
              prompt.identity == promptIdentity,
              prompt.isChooseUpgradeDeckPrompt,
              prompt.canUseCampaignDeckPrompt
        else {
            return .failed(campaignPromptLocalized(
                "campaign.error.deckPromptChanged",
                "This deck prompt changed. Review the game and try again."
            ))
        }
        guard let projection = liveGameStates[gameID]?.lastKnownProjection,
              projection.investigators.contains(where: { investigator in
                  investigator.playerID == playerID
                      && investigator.id.rawValue.rawValue == investigatorId.rawValue
              })
        else {
            return .failed(campaignPromptLocalized(
                "campaign.error.investigatorOwnerChanged",
                "This investigator is no longer yours to update."
            ))
        }
        return nil
    }

    private func submitCampaignDeck(
        deckURL: String?,
        deckList: DeckListInput?,
        investigatorId: InvestigatorCode,
        gameID: GameID,
        context: CampaignDeckSubmissionContext
    ) async -> CampaignDeckUpgradeSubmissionResult {
        if let failure = validateCampaignDeckPrompt(
            promptIdentity: context.promptIdentity,
            investigatorId: investigatorId,
            in: gameID
        ) {
            return failure
        }
        do {
            try await gameLifecycleService.chooseDeck(
                ChooseDeckRequest(
                    investigatorId: investigatorId,
                    deckUrl: deckURL,
                    deckList: deckList
                ),
                in: gameID,
                on: context.profile,
                token: context.deckContext.token
            )
            refreshGames()
            return .submitted
        } catch let error as GameLifecycleError {
            if case .sessionExpired = error {
                await handleDeckSessionExpired(
                    profile: context.profile,
                    context: context.deckContext
                )
            }
            return .failed(campaignDeckUpdateFailureMessage(error))
        } catch {
            return .failed(campaignPromptLocalized(
                "campaign.error.updateDeckFailed",
                "The server could not update that deck. Try again."
            ))
        }
    }
}

enum CampaignPromptLocalization {
    @TaskLocal static var localizationIdentifierOverride: String?

    @MainActor
    static func localized(_ key: String, _ fallback: String) -> String {
        let bundle: Bundle
        if let localizationIdentifierOverride,
           let path = Bundle.module.path(
               forResource: localizationIdentifierOverride,
               ofType: "lproj"
           ),
           let localizedBundle = Bundle(path: path) {
            bundle = localizedBundle
        } else {
            bundle = .module
        }
        return NSLocalizedString(key, bundle: bundle, value: fallback, comment: "")
    }
}

@MainActor
private func campaignPromptLocalized(_ key: String, _ fallback: String) -> String {
    CampaignPromptLocalization.localized(key, fallback)
}

@MainActor
private func campaignDeckFetchFailureMessage(_ error: DeckServiceError) -> String {
    switch error {
    case .operationFailed(let operationError):
        operationError.errorMsg
    case .sessionExpired:
        campaignPromptLocalized(
            "campaign.error.sessionExpiredDecks",
            "Your session expired. Sign in again to manage decks."
        )
    default:
        campaignPromptLocalized(
            "campaign.error.fetchDeckFailed",
            "The server could not fetch that deck. Try again."
        )
    }
}

@MainActor
private func campaignDeckUpdateFailureMessage(_ error: GameLifecycleError) -> String {
    switch error {
    case .operationFailed(let operationError):
        operationError.errorMsg
    case .sessionExpired:
        campaignPromptLocalized(
            "campaign.error.sessionExpiredDecks",
            "Your session expired. Sign in again to manage decks."
        )
    default:
        campaignPromptLocalized(
            "campaign.error.updateDeckFailed",
            "The server could not update that deck. Try again."
        )
    }
}
