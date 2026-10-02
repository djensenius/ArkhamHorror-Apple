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
}

extension AppModel {
    /// Fetches an ArkhamDB/arkham.build deck list with the same guarded import path used
    /// by the Decks screen, then submits it to the backend campaign deck endpoint. The
    /// server remains the deck-validation authority; this path only normalizes the source
    /// URL enough to ask the backend to fetch it.
    func upgradeCampaignDeck(
        from rawURL: String,
        investigatorId rawInvestigatorId: String,
        in gameID: GameID
    ) async -> CampaignDeckUpgradeSubmissionResult {
        let profile: ServerProfile
        guard case let .signedIn(signedInProfile, _, _) = sessionState else {
            return .failed("Sign in again to upgrade this deck.")
        }
        profile = signedInProfile

        let fetchURL: String
        do {
            fetchURL = try DeckImportURL.parse(rawURL).fetchURL
        } catch let error as DeckImportURL.ParseError {
            return .failed(error.message)
        } catch {
            return .failed(DeckImportURL.ParseError.invalid.message)
        }

        let context: DeckRequestContext
        do {
            context = try await currentDeckRequestContext(for: profile)
        } catch {
            return .failed("Your session expired. Sign in again to manage decks.")
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
            return .failed(error.message)
        } catch {
            return .failed("The server could not fetch that deck. Try again.")
        }

        return await submitCampaignDeck(
            deckURL: fetchURL,
            deckList: DeckListInput(deckList),
            investigatorId: rawInvestigatorId,
            gameID: gameID,
            context: CampaignDeckSubmissionContext(profile: profile, deckContext: context)
        )
    }

    func continueCampaignWithoutUpgrading(
        investigatorId rawInvestigatorId: String,
        in gameID: GameID
    ) async -> CampaignDeckUpgradeSubmissionResult {
        let profile: ServerProfile
        guard case let .signedIn(signedInProfile, _, _) = sessionState else {
            return .failed("Sign in again to continue this campaign.")
        }
        profile = signedInProfile

        let context: DeckRequestContext
        do {
            context = try await currentDeckRequestContext(for: profile)
        } catch {
            return .failed("Your session expired. Sign in again to manage decks.")
        }

        return await submitCampaignDeck(
            deckURL: nil,
            deckList: nil,
            investigatorId: rawInvestigatorId,
            gameID: gameID,
            context: CampaignDeckSubmissionContext(profile: profile, deckContext: context)
        )
    }

    private func submitCampaignDeck(
        deckURL: String?,
        deckList: DeckListInput?,
        investigatorId rawInvestigatorId: String,
        gameID: GameID,
        context: CampaignDeckSubmissionContext
    ) async -> CampaignDeckUpgradeSubmissionResult {
        guard let investigatorId = try? InvestigatorCode(rawInvestigatorId) else {
            return .failed("This investigator could not be sent safely.")
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
            return .failed(error.message)
        } catch {
            return .failed("The server could not update that deck. Try again.")
        }
    }
}
