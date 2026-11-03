import Foundation

/// An overwrite or save-as-new the user chose but has not yet confirmed.
struct ArkhamDBPendingResolution: Sendable, Equatable {
    let deckID: DeckID
    let resolution: ArkhamDBWriteBackResolution
}

extension ArkhamDBViewModel {
    /// The capability-gated write-back status of a saved deck, or nil when hidden.
    func writeBackStatus(for deckID: DeckID) -> ArkhamDBWriteBackStatus? {
        guard supportsWriteBack, status?.linked == true else { return nil }
        return writeBackStatuses[deckID]
    }

    var resolvingStatus: ArkhamDBWriteBackStatus? {
        resolvingDeckID.flatMap(writeBackStatus(for:))
    }

    func applyWriteBack(_ rows: [ArkhamDBWriteBackStatus]) {
        guard supportsWriteBack else {
            writeBackStatuses = [:]
            return
        }
        writeBackStatuses = Dictionary(rows.map { ($0.localDeckId, $0) }) { _, last in last }
    }

    func setWriteBack(_ deckID: DeckID, enabled: Bool) async {
        guard writeBackStatus(for: deckID) != nil else { return }
        await performWriteBack { context in
            try await self.service.setWriteBack(
                deckID: deckID, enabled: enabled, on: self.profile, token: context.token
            )
        }
    }

    func retryWriteBack(_ deckID: DeckID) async {
        guard writeBackStatus(for: deckID)?.canRetry == true else { return }
        await performWriteBack { context in
            try await self.service.retryWriteBack(
                deckID: deckID, on: self.profile, token: context.token
            )
        }
    }

    func openConflict(_ deckID: DeckID) {
        guard writeBackStatus(for: deckID)?.state == .conflict else { return }
        resolvingDeckID = deckID
    }

    /// Keep-remote is sent at once; overwrite and save-as-new only ask for confirmation.
    func chooseResolution(_ resolution: ArkhamDBWriteBackResolution, for deckID: DeckID) async {
        guard writeBackStatus(for: deckID)?.allowedResolutions.contains(resolution) == true
        else { return }
        if resolution.requiresConfirmation {
            pendingConfirmation = ArkhamDBPendingResolution(deckID: deckID, resolution: resolution)
            return
        }
        await resolve(deckID, resolution, confirmed: false)
    }

    func confirmPendingResolution() async {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        guard writeBackStatus(for: pending.deckID)?.allowedResolutions
            .contains(pending.resolution) == true
        else { return }
        await resolve(pending.deckID, pending.resolution, confirmed: true)
    }

    func cancelPendingResolution() {
        pendingConfirmation = nil
    }

    private func resolve(
        _ deckID: DeckID, _ resolution: ArkhamDBWriteBackResolution, confirmed: Bool
    ) async {
        let outcome = await performWriteBack { context in
            try await self.service.resolveConflict(
                deckID: deckID, resolution: resolution, confirmed: confirmed,
                on: self.profile, token: context.token
            )
        }
        if outcome == .succeeded, resolvingDeckID == deckID {
            resolvingDeckID = nil
        }
        // Save-as-new may add a campaign copy (`resultingLocalDeckId`) to saved decks. A
        // failed response may still have been applied (fail-closed decoding), so refresh
        // after any attempt that reached a refreshable failure too.
        if resolution == .saveAsNew, outcome != .skipped {
            await savedDecksChanged()
        }
    }

    enum WriteBackOutcome {
        /// Busy, session expired, cancelled or stale: nothing to refresh.
        case skipped
        case succeeded
        /// The request may or may not have been applied; status was refreshed.
        case failed
    }

    /// Applies the returned rows, or refreshes authoritative status after any failure
    /// (except session expiry, cancellation or a stale session) so the row never shows a
    /// stale state. A mutation can be applied even when its response is unreadable.
    @discardableResult
    private func performWriteBack(
        _ operation: @escaping (DeckRequestContext) async throws -> [ArkhamDBWriteBackStatus]
    ) async -> WriteBackOutcome {
        var outcome = WriteBackOutcome.skipped
        await perform { context in
            do {
                let rows = try await operation(context)
                try self.validate(context)
                self.applyWriteBack(rows)
                self.skippedWriteBackCount = 0
                outcome = .succeeded
            } catch {
                guard Self.refreshesAfter(error) else { throw error }
                outcome = .failed
                try? await self.updateStatus(context)
                throw error
            }
        }
        return outcome
    }

    private static func refreshesAfter(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError, GameLifecycleTokenAccessError.stale,
             DeckServiceError.sessionExpired:
            false
        default:
            true
        }
    }
}
