import Foundation
import Observation

@MainActor
@Observable
final class ArkhamDBViewModel {
    private let profile: ServerProfile
    private let service: ArkhamDBService
    private let authentication: (any ArkhamDBAuthenticating)?
    private let tokenProvider: DecksViewModel.TokenProvider
    private let contextValidator: DecksViewModel.ContextValidator
    private let sessionExpiredHandler: DecksViewModel.SessionExpiredHandler

    var status: ArkhamDBLinkStatus?
    var decks: [ArkhamDBRemoteDeckSummary] = []
    var skippedCount = 0
    var isBusy = false
    var message: String?
    var needsRelinking = false
    var confirmsUnlink = false

    init(
        profile: ServerProfile,
        service: ArkhamDBService,
        authentication: (any ArkhamDBAuthenticating)?,
        tokenProvider: @escaping DecksViewModel.TokenProvider,
        contextValidator: @escaping DecksViewModel.ContextValidator = { _ in true },
        sessionExpiredHandler: @escaping DecksViewModel.SessionExpiredHandler = { _ in }
    ) {
        self.profile = profile
        self.service = service
        self.authentication = authentication
        self.tokenProvider = tokenProvider
        self.contextValidator = contextValidator
        self.sessionExpiredHandler = sessionExpiredHandler
    }

    var statusText: String {
        guard let status else { return arkhamDBLocalized("loading") }
        guard status.linked else { return arkhamDBLocalized("unlinked") }
        if let name = status.remoteAccountName {
            return String(format: arkhamDBLocalized("linkedAs"), name)
        }
        return arkhamDBLocalized("linked")
    }

    func refreshStatus() async {
        await perform { context in
            try await self.updateStatus(context)
        }
    }

    func link() async {
        guard let authentication else { return }
        await perform { context in
            let start = try await self.service.startLink(on: self.profile, token: context.token)
            try self.validate(context)
            let callback = try await authentication.authenticate(url: start.authorizationURL())
            try self.validate(context)
            let request = try ArkhamDBLinkCompletionRequest(callback: callback)
            try await self.service.completeLink(request, on: self.profile, token: context.token)
            try self.validate(context)
            try await self.updateStatus(context)
        }
    }

    func unlink() async {
        confirmsUnlink = false
        await perform { context in
            try await self.service.unlink(on: self.profile, token: context.token)
            try self.validate(context)
            self.decks = []
            self.skippedCount = 0
            try await self.updateStatus(context)
        }
    }

    func loadDecks() async {
        await perform { context in try await self.updateDecks(context) }
    }

    func importDeck(_ deck: ArkhamDBRemoteDeckSummary, onImported: (Deck) -> Void) async {
        await perform { context in
            let imported = try await self.service.importDeck(
                ArkhamDBImportRequest(deckId: deck.id), on: self.profile, token: context.token
            )
            try self.validate(context)
            onImported(imported)
            try await self.updateDecks(context)
        }
    }

    private func validate(_ context: DeckRequestContext) throws {
        try Task.checkCancellation()
        guard contextValidator(context) else { throw GameLifecycleTokenAccessError.stale }
    }

    private func updateStatus(_ context: DeckRequestContext) async throws {
        let status = try await service.status(on: profile, token: context.token)
        try validate(context)
        self.status = status
        needsRelinking = false
        if !status.linked {
            decks = []
        }
    }

    private func updateDecks(_ context: DeckRequestContext) async throws {
        let list = try await service.listDecks(on: profile, token: context.token)
        try validate(context)
        decks = list.decks
        skippedCount = list.skippedCount
    }

    private func perform(_ operation: (DeckRequestContext) async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        var context: DeckRequestContext?
        do {
            let current = try await tokenProvider()
            context = current
            try validate(current)
            try await operation(current)
        } catch is CancellationError {
            // Cancelling the browser is not a failed link or a sign-out.
        } catch GameLifecycleTokenAccessError.stale {
            // Never install a callback or response into another app session.
        } catch {
            guard let context else {
                message = DecksViewModel.message(for: error)
                return
            }
            guard contextValidator(context) else { return }
            if let serviceError = error as? DeckServiceError {
                message = serviceError.message
                if case let .arkhamDB(remote) = serviceError {
                    needsRelinking = remote?.requiresRelinking == true
                }
                if serviceError == .sessionExpired {
                    await sessionExpiredHandler(context)
                }
            } else if error as? ArkhamDBLinkFlowError == .denied {
                message = arkhamDBLocalized("denied")
            } else {
                message = arkhamDBLocalized("failed")
            }
        }
    }
}
