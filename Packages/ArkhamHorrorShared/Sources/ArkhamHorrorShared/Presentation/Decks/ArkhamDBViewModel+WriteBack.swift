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

    /// Applies authoritative rows. Resolutions complete asynchronously on the server, so
    /// saved decks are reloaded once when a tracked keep-remote/save-as-new leaves
    /// pending/running, when a known row's `resultingLocalDeckId` appears or changes, or
    /// when a row appears for a local deck no earlier row named (a save-as-new clone split
    /// off while the original row stays pending for another campaign). The first snapshot
    /// never reloads: a clone always derives from an existing row, so it can only appear
    /// after a non-empty snapshot.
    func applyWriteBack(_ rows: [ArkhamDBWriteBackStatus]) async {
        guard supportsWriteBack else {
            writeBackStatuses = [:]
            awaitingResolutionDeckIDs = []
            return
        }
        let previous = writeBackStatuses
        writeBackStatuses = Dictionary(rows.map { ($0.localDeckId, $0) }) { _, last in last }
        awaitingResolutionDeckIDs.formIntersection(writeBackStatuses.keys)
        let knownDeckIDs = Set(previous.keys)
            .union(previous.values.compactMap(\.resultingLocalDeckId))
        var reload = !previous.isEmpty
            && writeBackStatuses.keys.contains { !knownDeckIDs.contains($0) }
        for (deckID, row) in writeBackStatuses {
            let resultChanged = previous[deckID].map {
                row.resultingLocalDeckId != nil
                    && row.resultingLocalDeckId != $0.resultingLocalDeckId
            } ?? false
            let completed = awaitingResolutionDeckIDs.contains(deckID)
                && row.state.endsTrackedResolution
            if resultChanged || completed {
                awaitingResolutionDeckIDs.remove(deckID)
                reload = true
            }
        }
        if reload {
            await savedDecksChanged()
        }
    }

    func setWriteBack(_ deckID: DeckID, enabled: Bool) async {
        guard writeBackStatus(for: deckID) != nil else { return }
        await performWriteBack { context in
            try await self.service.setWriteBack(
                deckID: deckID, enabled: enabled, on: self.profile, token: context.token
            )
        }
    }

    /// Retry resumes a durable stage that may still re-sync or clone a saved deck, so the
    /// deck is tracked until its completion shows up in status.
    func retryWriteBack(_ deckID: DeckID) async {
        guard writeBackStatus(for: deckID)?.canRetry == true else { return }
        var inserted = false
        let outcome = await performWriteBack {
            inserted = self.awaitingResolutionDeckIDs.insert(deckID).inserted
        } operation: { context in
            try await self.service.retryWriteBack(
                deckID: deckID, on: self.profile, token: context.token
            )
        }
        if outcome == .skipped, inserted {
            awaitingResolutionDeckIDs.remove(deckID)
        }
        startPollingIfAwaiting(deckID, after: outcome)
    }

    /// Opens the resolution sheet for a conflict or a resolvable failed push. Any
    /// confirmation left from another deck is dropped so it can never reappear here.
    func openResolution(_ deckID: DeckID) {
        guard writeBackStatus(for: deckID)?.opensResolution == true else { return }
        pendingConfirmation = nil
        resolvingDeckID = deckID
    }

    func closeResolution() {
        pendingConfirmation = nil
        resolvingDeckID = nil
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

    /// Confirms `captured` (the dialog's presented value), or the current confirmation.
    /// The dialog may clear `pendingConfirmation` on dismissal before this runs, so the
    /// captured value is used, and every safety check is made against current state.
    func confirmPendingResolution(_ captured: ArkhamDBPendingResolution? = nil) async {
        guard let pending = captured ?? pendingConfirmation else { return }
        if pendingConfirmation == pending {
            pendingConfirmation = nil
        }
        guard pending.deckID == resolvingDeckID,
              writeBackStatus(for: pending.deckID)?.allowedResolutions
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
        let tracks = resolution == .keepRemote || resolution == .saveAsNew
        // Only this call's own insertion is undone if it is skipped; an earlier in-flight
        // resolution for the same deck keeps its tracker.
        var inserted = false
        let outcome = await performWriteBack {
            inserted = tracks && self.awaitingResolutionDeckIDs.insert(deckID).inserted
        } operation: { context in
            try await self.service.resolveConflict(
                deckID: deckID, resolution: resolution, confirmed: confirmed,
                on: self.profile, token: context.token
            )
        }
        if outcome == .succeeded, resolvingDeckID == deckID {
            resolvingDeckID = nil
        }
        switch outcome {
        case .skipped:
            // Nothing was sent (busy, cancelled, stale or expired session).
            if inserted {
                awaitingResolutionDeckIDs.remove(deckID)
            }
        case .succeeded:
            // Completion is observed through later status rows (see applyWriteBack).
            break
        case .failed:
            // A save-as-new response may have been applied despite failing (fail-closed
            // decoding). Reload now unless the refreshed rows already did; keep tracking
            // so a later completion reloads again.
            if resolution == .saveAsNew, awaitingResolutionDeckIDs.contains(deckID) {
                await savedDecksChanged()
            }
        }
        startPollingIfAwaiting(deckID, after: outcome)
    }

    /// A sent request whose completion is still awaited starts a new polling episode.
    private func startPollingIfAwaiting(_ deckID: DeckID, after outcome: WriteBackOutcome) {
        if outcome != .skipped, awaitingResolutionDeckIDs.contains(deckID) {
            writeBackPollEpisode += 1
        }
    }

    enum WriteBackOutcome {
        /// Busy, session expired, cancelled or stale: nothing to refresh.
        case skipped
        case succeeded
        /// The request may or may not have been applied; a status refresh was attempted.
        case failed
    }

    /// Applies the returned rows, or refreshes authoritative status after any failure
    /// (except session expiry, cancellation or a stale session) so the row never shows a
    /// stale state. A mutation can be applied even when its response is unreadable.
    /// `beforeSend` runs after `perform` has waited out any status poll and validated the
    /// context: a completion tracker inserted earlier could be cleared by a poll applying
    /// the deck's pre-request status. The request may still suspend before it is sent (the
    /// app-wide gate wait and the main-actor `sendCheck` hop); the ordering holds because
    /// `waitForStatusPoll` drained any running poll and `isBusy` blocks new poll ticks.
    @discardableResult
    private func performWriteBack(
        beforeSend: @escaping () -> Void = {},
        operation: @escaping (DeckRequestContext) async throws -> [ArkhamDBWriteBackStatus]
    ) async -> WriteBackOutcome {
        var outcome = WriteBackOutcome.skipped
        await perform { context in
            self.writeBackPollContext = context
            beforeSend()
            do {
                let rows = try await operation(context)
                try self.validate(context)
                await self.applyWriteBack(rows)
                try self.validate(context)
                self.skippedWriteBackCount = 0
                outcome = .succeeded
            } catch let writeBackError {
                guard Self.refreshesAfter(writeBackError) else { throw writeBackError }
                outcome = .failed
                do {
                    try await self.updateStatus(context)
                } catch let refreshError where !Self.refreshesAfter(refreshError) {
                    // Session expiry, cancellation or a stale session during recovery
                    // outranks the write-back error, so perform handles it.
                    outcome = .skipped
                    throw refreshError
                } catch let refreshError {
                    // A refresh saying ArkhamDB needs relinking outranks the write-back
                    // error, so perform sets needsRelinking and shows the relink message.
                    if (refreshError as? DeckServiceError)?.isArkhamDBRelinkRequired == true {
                        throw refreshError
                    }
                    // An ordinary refresh failure keeps the write-back error below, but a
                    // conflict must not claim that the status was refreshed.
                    if (writeBackError as? DeckServiceError)?.isArkhamDBConflict == true {
                        throw DeckServiceError.writeBackConflictStatusUnavailable
                    }
                }
                throw writeBackError
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
