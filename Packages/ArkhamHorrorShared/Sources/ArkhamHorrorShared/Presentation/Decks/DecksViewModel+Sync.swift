import Foundation

extension DecksViewModel {
    fileprivate enum SyncOutcome: Sendable {
        case succeeded(requestedID: DeckID, Deck)
        case failed(DeckID, String)
        case sessionExpired(DeckID)
        case cancelled(DeckID)
    }

    private struct SyncAllProgress {
        var nextIndex = 0
        var started = 0
        var succeeded = 0
        var failed = 0
        var didExpireSession = false
        var didBecomeStale = false
    }

    func refreshAndSync() async {
        guard !isSyncingAll, syncingDeckIDs.isEmpty else { return }
        isSyncingAll = true
        defer {
            for deckID in syncingDeckIDs {
                deckSyncStates[deckID] = nil
            }
            syncingDeckIDs = []
            isSyncingAll = false
        }
        loadState = .loading
        syncAllSummary = nil
        deckSyncStates = [:]
        syncingDeckIDs = []
        var requestContext: DeckRequestContext?
        do {
            let context = try await tokenProvider()
            requestContext = context
            let loaded = try await deckService.listDecks(on: profile, token: context.token)
                .sortedForPresentation()
            guard contextValidator(context) else { throw GameLifecycleTokenAccessError.stale }
            loadState = .loaded(loaded)
            await loadedDecksRecorder(loaded)
            guard await syncDecksWithURL(loaded, context: context) else {
                throw GameLifecycleTokenAccessError.stale
            }
        } catch is CancellationError {
            loadState = .idle
        } catch GameLifecycleTokenAccessError.stale {
            loadState = .idle
        } catch DeckServiceError.sessionExpired {
            loadState = .failed(DeckServiceError.sessionExpired.message)
            if let requestContext {
                await sessionExpiredHandler(requestContext)
            }
        } catch {
            loadState = .failed(Self.message(for: error))
        }
    }

    func sync(_ deck: Deck) async {
        guard deck.hasSyncURL, !isSyncingAll, !syncingDeckIDs.contains(deck.id) else { return }
        syncingDeckIDs.insert(deck.id)
        deckSyncStates[deck.id] = .syncing
        syncAllSummary = nil
        var requestContext: DeckRequestContext?
        do {
            let context = try await tokenProvider()
            requestContext = context
            let syncedDeck = try await deckService.syncDeck(
                deck.id,
                on: profile,
                token: context.token,
                timeout: 10
            )
            guard contextValidator(context) else { throw GameLifecycleTokenAccessError.stale }
            await deckSyncTracker?.recordSync(syncedDeck, on: profile, at: Date())
            guard contextValidator(context) else {
                await deckSyncTracker?.removeSync(for: deck.id, on: profile)
                syncingDeckIDs.remove(deck.id)
                deckSyncStates[deck.id] = nil
                return
            }
            guard !deletedDeckIDs.contains(deck.id) else {
                syncingDeckIDs.remove(deck.id)
                deckSyncStates[deck.id] = nil
                return
            }
            upsert(syncedDeck)
            syncingDeckIDs.remove(deck.id)
            deckSyncStates[deck.id] = .succeeded(deckSyncSuccessMessage())
            syncedDeckRecorder(syncedDeck)
        } catch is CancellationError {
            syncingDeckIDs.remove(deck.id)
            deckSyncStates[deck.id] = nil
        } catch GameLifecycleTokenAccessError.stale {
            syncingDeckIDs.remove(deck.id)
            deckSyncStates[deck.id] = nil
        } catch DeckServiceError.sessionExpired {
            syncingDeckIDs.remove(deck.id)
            deckSyncStates[deck.id] = .failed(DeckServiceError.sessionExpired.message)
            if let requestContext {
                await sessionExpiredHandler(requestContext)
            }
        } catch {
            syncingDeckIDs.remove(deck.id)
            deckSyncStates[deck.id] = .failed(Self.message(for: error))
        }
    }

    func syncState(for deck: Deck) -> SyncState? {
        deckSyncStates[deck.id]
    }

    private func syncDecksWithURL(
        _ loadedDecks: [Deck],
        context: DeckRequestContext
    ) async -> Bool {
        let syncableDecks = uniqueSyncableDecks(from: loadedDecks)
        guard !syncableDecks.isEmpty else {
            syncAllSummary = deckLocalized(
                "deck.syncAll.none",
                "No decks with a deck source to sync."
            )
            return true
        }
        var progress = SyncAllProgress()
        await withTaskGroup(of: SyncOutcome.self) { group in
            enqueueInitialSyncs(
                from: syncableDecks,
                context: context,
                progress: &progress,
                group: &group
            )
            while let outcome = await group.next() {
                guard !Task.isCancelled else {
                    progress.didBecomeStale = true
                    group.cancelAll()
                    break
                }
                if !contextValidator(context) {
                    progress.didBecomeStale = true
                    group.cancelAll()
                }
                guard await applySyncOutcome(
                    outcome,
                    context: context,
                    progress: &progress,
                    group: &group
                ) else { continue }
                enqueueNextSync(
                    from: syncableDecks,
                    context: context,
                    progress: &progress,
                    group: &group
                )
            }
        }
        guard !progress.didBecomeStale else { return false }
        syncAllSummary = deckLocalizedFormat(
            "deck.syncAll.summary",
            "Synced %1$lld of %2$lld decks with a deck source. %3$lld failed.",
            progress.succeeded,
            progress.started,
            progress.failed
        )
        return true
    }

    private func uniqueSyncableDecks(from loadedDecks: [Deck]) -> [Deck] {
        var seenDeckIDs: Set<DeckID> = []
        return loadedDecks.filter { deck in
            deck.hasSyncURL && seenDeckIDs.insert(deck.id).inserted
        }
    }

    private func enqueueInitialSyncs(
        from syncableDecks: [Deck],
        context: DeckRequestContext,
        progress: inout SyncAllProgress,
        group: inout TaskGroup<SyncOutcome>
    ) {
        let maxConcurrentSyncs = min(3, syncableDecks.count)
        for _ in 0 ..< maxConcurrentSyncs {
            enqueueNextSync(
                from: syncableDecks,
                context: context,
                progress: &progress,
                group: &group
            )
        }
    }

    private func enqueueNextSync(
        from syncableDecks: [Deck],
        context: DeckRequestContext,
        progress: inout SyncAllProgress,
        group: inout TaskGroup<SyncOutcome>
    ) {
        guard !progress.didExpireSession,
              !progress.didBecomeStale,
              !Task.isCancelled
        else { return }
        guard contextValidator(context) else {
            progress.didBecomeStale = true
            group.cancelAll()
            return
        }
        guard progress.nextIndex < syncableDecks.count else { return }
        let deck = syncableDecks[progress.nextIndex]
        progress.nextIndex += 1
        progress.started += 1
        syncingDeckIDs.insert(deck.id)
        deckSyncStates[deck.id] = .syncing
        let service = deckService
        let profile = profile
        group.addTask {
            await Self.syncOutcome(for: deck, service: service, profile: profile, context: context)
        }
    }

    /// Returns whether to enqueue the next deck after applying this outcome.
    private func applySyncOutcome(
        _ outcome: SyncOutcome,
        context: DeckRequestContext,
        progress: inout SyncAllProgress,
        group: inout TaskGroup<SyncOutcome>
    ) async -> Bool {
        switch outcome {
        case let .succeeded(requestedID, deck):
            return await applySucceededSync(
                deck,
                requestedID: requestedID,
                context: context,
                progress: &progress,
                group: &group
            )
        case let .failed(deckID, message):
            return applyFailedSync(deckID, message: message, progress: &progress)
        case let .sessionExpired(deckID):
            return await applySessionExpiredSync(
                deckID,
                context: context,
                progress: &progress,
                group: &group
            )
        case let .cancelled(deckID):
            syncingDeckIDs.remove(deckID)
            deckSyncStates[deckID] = nil
            return true
        }
    }

    private func applySucceededSync(
        _ deck: Deck,
        requestedID: DeckID,
        context: DeckRequestContext,
        progress: inout SyncAllProgress,
        group: inout TaskGroup<SyncOutcome>
    ) async -> Bool {
        guard !progress.didExpireSession, !progress.didBecomeStale else {
            syncingDeckIDs.remove(requestedID)
            deckSyncStates[requestedID] = nil
            return false
        }
        guard !deletedDeckIDs.contains(requestedID) else {
            syncingDeckIDs.remove(requestedID)
            deckSyncStates[requestedID] = nil
            return true
        }
        await deckSyncTracker?.recordSync(deck, on: profile, at: Date())
        guard !progress.didExpireSession, !Task.isCancelled, contextValidator(context) else {
            progress.didBecomeStale = true
            await deckSyncTracker?.removeSync(for: requestedID, on: profile)
            syncingDeckIDs.remove(requestedID)
            deckSyncStates[requestedID] = nil
            group.cancelAll()
            return false
        }
        progress.succeeded += 1
        upsert(deck)
        syncingDeckIDs.remove(requestedID)
        deckSyncStates[requestedID] = .succeeded(deckSyncSuccessMessage())
        syncedDeckRecorder(deck)
        return true
    }

    private func applyFailedSync(
        _ deckID: DeckID,
        message: String,
        progress: inout SyncAllProgress
    ) -> Bool {
        guard !progress.didExpireSession, !progress.didBecomeStale else {
            syncingDeckIDs.remove(deckID)
            deckSyncStates[deckID] = nil
            return false
        }
        progress.failed += 1
        syncingDeckIDs.remove(deckID)
        deckSyncStates[deckID] = .failed(message)
        return true
    }

    private func applySessionExpiredSync(
        _ deckID: DeckID,
        context: DeckRequestContext,
        progress: inout SyncAllProgress,
        group: inout TaskGroup<SyncOutcome>
    ) async -> Bool {
        guard !progress.didBecomeStale else {
            syncingDeckIDs.remove(deckID)
            deckSyncStates[deckID] = nil
            return false
        }
        progress.failed += 1
        syncingDeckIDs.remove(deckID)
        deckSyncStates[deckID] = .failed(DeckServiceError.sessionExpired.message)
        if !progress.didExpireSession {
            progress.didExpireSession = true
            group.cancelAll()
            await sessionExpiredHandler(context)
        }
        return true
    }
}

private extension DecksViewModel {
    nonisolated static func syncOutcome(
        for deck: Deck,
        service: any DeckServicing,
        profile: ServerProfile,
        context: DeckRequestContext
    ) async -> SyncOutcome {
        do {
            let syncedDeck = try await service.syncDeck(
                deck.id,
                on: profile,
                token: context.token,
                timeout: 10
            )
            return .succeeded(requestedID: deck.id, syncedDeck)
        } catch is CancellationError {
            return .cancelled(deck.id)
        } catch GameLifecycleTokenAccessError.stale {
            return .cancelled(deck.id)
        } catch DeckServiceError.sessionExpired {
            return .sessionExpired(deck.id)
        } catch {
            return .failed(deck.id, message(for: error))
        }
    }
}
