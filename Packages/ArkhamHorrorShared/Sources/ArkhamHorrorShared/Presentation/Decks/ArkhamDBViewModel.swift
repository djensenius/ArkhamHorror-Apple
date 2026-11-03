import Foundation
import Observation

@MainActor
@Observable
final class ArkhamDBViewModel {
    let profile: ServerProfile
    let service: ArkhamDBService
    private let authentication: (any ArkhamDBAuthenticating)?
    private let tokenProvider: DecksViewModel.TokenProvider
    private let contextValidator: DecksViewModel.ContextValidator
    private let sessionExpiredHandler: DecksViewModel.SessionExpiredHandler
    /// `arkhamdb.write-back.v1`; without it no write-back state or control is exposed.
    let supportsWriteBack: Bool
    let savedDecksChanged: @MainActor () async -> Void

    var status: ArkhamDBLinkStatus?
    var decks: [ArkhamDBRemoteDeckSummary] = []
    var skippedCount = 0
    var hasLoadedDecks = false
    var isDeckBrowserOpen = false
    var isBusy = false
    var message: String?
    var needsRelinking = false
    var confirmsUnlink = false
    var writeBackStatuses: [DeckID: ArkhamDBWriteBackStatus] = [:]
    var skippedWriteBackCount = 0
    /// The deck whose conflict sheet is open.
    var resolvingDeckID: DeckID?
    /// An overwrite or save-as-new awaiting explicit confirmation; nothing is sent yet.
    var pendingConfirmation: ArkhamDBPendingResolution?
    /// Decks with a submitted keep-remote or save-as-new whose asynchronous completion
    /// (which re-syncs or clones a saved deck) has not yet been observed in status.
    var awaitingResolutionDeckIDs: Set<DeckID> = []

    init(
        profile: ServerProfile,
        service: ArkhamDBService,
        authentication: (any ArkhamDBAuthenticating)?,
        tokenProvider: @escaping DecksViewModel.TokenProvider,
        contextValidator: @escaping DecksViewModel.ContextValidator = { _ in true },
        sessionExpiredHandler: @escaping DecksViewModel.SessionExpiredHandler = { _ in },
        supportsWriteBack: Bool = false,
        savedDecksChanged: @escaping @MainActor () async -> Void = {}
    ) {
        self.profile = profile
        self.service = service
        self.authentication = authentication
        self.tokenProvider = tokenProvider
        self.contextValidator = contextValidator
        self.sessionExpiredHandler = sessionExpiredHandler
        self.supportsWriteBack = supportsWriteBack
        self.savedDecksChanged = savedDecksChanged
    }

    var statusText: String {
        guard let status else {
            return arkhamDBLocalized(isBusy ? "loading" : "statusUnavailable")
        }
        guard status.linked else { return arkhamDBLocalized("unlinked") }
        if let name = status.remoteAccountName {
            return String(format: arkhamDBLocalized("linkedAs"), name)
        }
        return arkhamDBLocalized("linked")
    }

    var showsEmptyDecks: Bool {
        hasLoadedDecks && !isBusy && decks.isEmpty && message == nil
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
            self.decks = []
            self.skippedCount = 0
            self.hasLoadedDecks = false
            try await self.updateStatus(context)
            if self.isDeckBrowserOpen {
                try await self.updateDecks(context)
            }
        }
    }

    func unlink() async {
        confirmsUnlink = false
        await perform { context in
            try await self.service.unlink(on: self.profile, token: context.token)
            try self.validate(context)
            self.status = nil
            self.writeBackStatuses = [:]
            self.awaitingResolutionDeckIDs = []
            self.skippedWriteBackCount = 0
            self.decks = []
            self.skippedCount = 0
            self.hasLoadedDecks = false
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

    func validate(_ context: DeckRequestContext) throws {
        try Task.checkCancellation()
        guard contextValidator(context) else { throw GameLifecycleTokenAccessError.stale }
    }

    func updateStatus(_ context: DeckRequestContext) async throws {
        let status = try await service.status(on: profile, token: context.token)
        try validate(context)
        self.status = status
        needsRelinking = false
        await applyWriteBack(status.linked ? status.deckLinks : [])
        // The saved-deck reload may suspend; never write into a session that went stale.
        try validate(context)
        skippedWriteBackCount = status.linked ? status.skippedDeckLinkCount : 0
        if !status.linked {
            decks = []
            skippedCount = 0
            hasLoadedDecks = false
        }
    }

    private func updateDecks(_ context: DeckRequestContext) async throws {
        let list = try await service.listDecks(on: profile, token: context.token)
        try validate(context)
        decks = list.decks
        skippedCount = list.skippedCount
        hasLoadedDecks = true
        needsRelinking = false
    }

    func perform(_ operation: (DeckRequestContext) async throws -> Void) async {
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
            } else if error is ArkhamDBResolveConflictRequest.ValidationError {
                // Unreachable through the UI, which confirms first; never show "failed".
                message = arkhamDBLocalized("writeBack.error.confirmationRequired")
            } else {
                message = arkhamDBLinkErrorMessage(error as? ArkhamDBLinkFlowError)
            }
        }
    }
}
