import Foundation

// swiftlint:disable file_length

enum CampaignDeckUpgradeSubmissionResult: Sendable, Equatable {
    case submitted
    case failed(String)

    var failureMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}

enum CampaignDeckSubmissionPhase: Sendable, Equatable {
    case submitting
    case awaitingSnapshot
}

struct CampaignDeckSubmissionAttempt: Sendable {
    let attemptID: UUID
    let promptIdentity: BasicChoicePromptIdentity
    let phase: CampaignDeckSubmissionPhase
    let task: Task<CampaignDeckUpgradeSubmissionResult, Never>?
}

private enum CampaignDeckSubmissionStart: Sendable {
    case started(UUID)
    case failed(CampaignDeckUpgradeSubmissionResult)
}

private struct CampaignDeckSubmissionContext: Sendable {
    let profile: ServerProfile
    let deckContext: DeckRequestContext
    let promptIdentity: BasicChoicePromptIdentity
}

extension AppModel {
    // Fetches an ArkhamDB/arkham.build deck list with the same guarded import path used
    // by the Decks screen, then submits it to the backend campaign deck endpoint. The
    // server remains the deck-validation authority; this path only normalizes the source
    // URL enough to ask the backend to fetch it.
    // swiftlint:disable:next function_body_length
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
        let attemptID: UUID
        switch beginCampaignDeckSubmission(
            promptIdentity: promptIdentity,
            investigatorId: investigatorId,
            in: gameID
        ) {
        case let .started(value):
            attemptID = value
        case let .failed(failure):
            return failure
        }

        let task = Task<CampaignDeckUpgradeSubmissionResult, Never> { @MainActor in
            await self.performCampaignDeckUpgrade(
                rawURL: rawURL,
                investigatorId: investigatorId,
                gameID: gameID,
                profile: profile,
                promptIdentity: promptIdentity
            )
        }
        campaignDeckSubmissions[gameID] = CampaignDeckSubmissionAttempt(
            attemptID: attemptID,
            promptIdentity: promptIdentity,
            phase: .submitting,
            task: task
        )
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        finishCampaignDeckSubmission(
            gameID: gameID,
            attemptID: attemptID,
            promptIdentity: promptIdentity,
            result: result
        )
        return result
    }

    // swiftlint:disable:next function_body_length
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
        let attemptID: UUID
        switch beginCampaignDeckSubmission(
            promptIdentity: promptIdentity,
            investigatorId: investigatorId,
            in: gameID
        ) {
        case let .started(value):
            attemptID = value
        case let .failed(failure):
            return failure
        }

        let task = Task<CampaignDeckUpgradeSubmissionResult, Never> { @MainActor in
            await self.performCampaignDeckSkip(
                investigatorId: investigatorId,
                gameID: gameID,
                profile: profile,
                promptIdentity: promptIdentity
            )
        }
        campaignDeckSubmissions[gameID] = CampaignDeckSubmissionAttempt(
            attemptID: attemptID,
            promptIdentity: promptIdentity,
            phase: .submitting,
            task: task
        )
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        finishCampaignDeckSubmission(
            gameID: gameID,
            attemptID: attemptID,
            promptIdentity: promptIdentity,
            result: result
        )
        return result
    }

    // swiftlint:disable:next function_body_length
    private func performCampaignDeckUpgrade(
        rawURL: String,
        investigatorId: InvestigatorCode,
        gameID: GameID,
        profile: ServerProfile,
        promptIdentity: BasicChoicePromptIdentity
    ) async -> CampaignDeckUpgradeSubmissionResult {
        guard !Task.isCancelled else { return campaignDeckSubmissionCancelledFailure() }
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
        } catch is CancellationError {
            return campaignDeckSubmissionCancelledFailure()
        } catch {
            return .failed(campaignPromptLocalized(
                "campaign.error.sessionExpiredDecks",
                "Your session expired. Sign in again to manage decks."
            ))
        }
        guard !Task.isCancelled else { return campaignDeckSubmissionCancelledFailure() }

        let deckList: DeckList
        do {
            deckList = try await deckService.fetchDeckList(
                FetchDeckRequest(url: fetchURL), on: profile, token: context.token
            )
        } catch is CancellationError {
            return campaignDeckSubmissionCancelledFailure()
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
        guard !Task.isCancelled else { return campaignDeckSubmissionCancelledFailure() }

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

    private func performCampaignDeckSkip(
        investigatorId: InvestigatorCode,
        gameID: GameID,
        profile: ServerProfile,
        promptIdentity: BasicChoicePromptIdentity
    ) async -> CampaignDeckUpgradeSubmissionResult {
        guard !Task.isCancelled else { return campaignDeckSubmissionCancelledFailure() }
        let context: DeckRequestContext
        do {
            context = try await currentDeckRequestContext(for: profile)
        } catch is CancellationError {
            return campaignDeckSubmissionCancelledFailure()
        } catch {
            return .failed(campaignPromptLocalized(
                "campaign.error.sessionExpiredDecks",
                "Your session expired. Sign in again to manage decks."
            ))
        }
        guard !Task.isCancelled else { return campaignDeckSubmissionCancelledFailure() }

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
    ) -> CampaignDeckSubmissionStart {
        if let failure = validateCampaignDeckPrompt(
            promptIdentity: promptIdentity,
            investigatorId: investigatorId,
            in: gameID
        ) {
            return .failed(failure)
        }
        if let existing = campaignDeckSubmissions[gameID] {
            guard existing.promptIdentity.promptKey == promptIdentity.promptKey else {
                existing.task?.cancel()
                campaignDeckSubmissions[gameID] = nil
                return beginCampaignDeckSubmission(
                    promptIdentity: promptIdentity,
                    investigatorId: investigatorId,
                    in: gameID
                )
            }
            switch existing.phase {
            case .submitting:
                return .failed(.failed(campaignPromptLocalized(
                    "campaign.error.deckSubmissionInFlight",
                    "A deck update is already being submitted."
                )))
            case .awaitingSnapshot:
                return .failed(.failed(campaignDeckSubmissionAwaitingSnapshotMessage()))
            }
        }
        let attemptID = UUID()
        campaignDeckSubmissions[gameID] = CampaignDeckSubmissionAttempt(
            attemptID: attemptID,
            promptIdentity: promptIdentity,
            phase: .submitting,
            task: nil
        )
        return .started(attemptID)
    }

    private func finishCampaignDeckSubmission(
        gameID: GameID,
        attemptID: UUID,
        promptIdentity: BasicChoicePromptIdentity,
        result: CampaignDeckUpgradeSubmissionResult
    ) {
        guard campaignDeckSubmissions[gameID]?.attemptID == attemptID else { return }
        switch result {
        case .submitted where isCampaignDeckPromptCurrent(promptIdentity):
            campaignDeckSubmissions[gameID] = CampaignDeckSubmissionAttempt(
                attemptID: attemptID,
                promptIdentity: promptIdentity,
                phase: .awaitingSnapshot,
                task: nil
            )
        case .submitted, .failed:
            campaignDeckSubmissions[gameID] = nil
        }
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
        guard !Task.isCancelled else { return campaignDeckSubmissionCancelledFailure() }
        if let failure = validateCampaignDeckPrompt(
            promptIdentity: context.promptIdentity,
            investigatorId: investigatorId,
            in: gameID
        ) {
            return failure
        }
        guard !Task.isCancelled else { return campaignDeckSubmissionCancelledFailure() }
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
            guard !Task.isCancelled else { return campaignDeckSubmissionCancelledFailure() }
            refreshGames()
            return .submitted
        } catch is CancellationError {
            return campaignDeckSubmissionCancelledFailure()
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

    func isCampaignDeckSubmissionAwaitingSnapshot(
        for promptIdentity: BasicChoicePromptIdentity
    ) -> Bool {
        guard let submission = campaignDeckSubmissions[promptIdentity.gameID],
              submission.phase == .awaitingSnapshot,
              submission.promptIdentity.promptKey == promptIdentity.promptKey,
              isCampaignDeckPromptCurrent(promptIdentity)
        else { return false }
        return true
    }

    func reconcileCampaignDeckSubmission(gameID: GameID, projection: BoardProjection) {
        guard let submission = campaignDeckSubmissions[gameID] else { return }
        switch submission.phase {
        case .submitting:
            return
        case .awaitingSnapshot:
            guard campaignDeckPromptKey(
                in: projection,
                gameID: gameID,
                ownerID: submission.promptIdentity.ownerID
            ) == submission.promptIdentity.promptKey
            else {
                campaignDeckSubmissions[gameID] = nil
                return
            }
        }
    }

    private func isCampaignDeckPromptCurrent(
        _ promptIdentity: BasicChoicePromptIdentity
    ) -> Bool {
        guard let prompt = basicChoicePresentation(for: promptIdentity.gameID) else { return false }
        return prompt.identity.promptKey == promptIdentity.promptKey
            && prompt.isChooseUpgradeDeckPrompt
    }

    private func campaignDeckPromptKey(
        in projection: BoardProjection,
        gameID: GameID,
        ownerID: PlayerID
    ) -> BasicChoicePromptKey? {
        guard let payload = projection.questions[ownerID] else { return nil }
        return basicChoicePromptKey(
            gameID: gameID, ownerID: ownerID, payload: payload, projection: projection
        )
    }
}

enum CampaignPromptLocalization {
    @TaskLocal static var localizationIdentifierOverride: String?

    static func localized(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(
            key,
            bundle: bundle(for: localizationIdentifierOverride),
            value: fallback,
            comment: ""
        )
    }

    private static func bundle(for localizationIdentifier: String?) -> Bundle {
        guard let localizationIdentifier,
              let path = Bundle.module.path(
                  forResource: localizationIdentifier,
                  ofType: "lproj"
              ),
              let localizedBundle = Bundle(path: path)
        else { return .module }
        return localizedBundle
    }
}

@MainActor
private func campaignPromptLocalized(_ key: String, _ fallback: String) -> String {
    CampaignPromptLocalization.localized(key, fallback)
}

@MainActor
private func campaignDeckSubmissionCancelledFailure() -> CampaignDeckUpgradeSubmissionResult {
    .failed(campaignPromptLocalized(
        "campaign.error.deckPromptChanged",
        "This deck prompt changed. Review the game and try again."
    ))
}

@MainActor
func campaignDeckSubmissionAwaitingSnapshotMessage() -> String {
    campaignPromptLocalized(
        "campaign.status.deckSubmissionAwaitingSnapshot",
        "Deck update sent. Waiting for the game to update…"
    )
}

@MainActor
private func campaignDeckFetchFailureMessage(_ error: DeckServiceError) -> String {
    switch error {
    case let .operationFailed(operationError):
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
    case let .operationFailed(operationError):
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
