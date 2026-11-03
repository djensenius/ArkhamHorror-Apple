import Foundation

/// Keep-remote, save-as-new and retry return at once; the server finishes them in the
/// background, so status is refreshed on a bounded schedule until completion shows up
/// (`applyWriteBack` then reloads saved decks once and stops tracking).
///
/// Known limits:
/// - Status reports only each linked deck's oldest unfinished push, so a resolved push
///   can stay "pending" behind another campaign's push. The attempt cap bounds that.
/// - Every ArkhamDB request goes through `ArkhamDBService`'s app-wide gate. A poll asks
///   it at background priority and never waits: while any request (including a deck sync
///   from `DecksViewModel` or `AppModel`) is in flight or a user request is waiting, the
///   tick is deferred like a busy tick.
/// - The gate covers only the request, so this view model still keeps its own user
///   requests behind a whole poll (`waitForStatusPoll`): a poll applying its response
///   after a write-back's `beforeSend` could clear the new completion tracker.
/// - A poll that finds the app session expired stops quietly; the next user request
///   reports the expiry.
extension ArkhamDBViewModel {
    /// The server's dispatcher runs every 30 s, admits each user at most once per 30 s
    /// and backs off failures (60/120/240 s, capped at 5 min); polls never ask sooner.
    static let writeBackPollDelays: [Duration] = [30, 60, 120, 240, 300, 300]
        .map { .seconds($0) }

    var isAwaitingWriteBackCompletion: Bool {
        supportsWriteBack && status?.linked == true && !awaitingResolutionDeckIDs.isEmpty
    }

    /// Runs one polling episode; drive it from a view `.task` so dismissal cancels it.
    /// Stops when nothing is awaited (completion, unlink), after the last attempt, when
    /// the app session or profile changed, or when write-back is no longer available.
    /// A tick that finds a user request in flight, or the app-wide ArkhamDB gate in use,
    /// is deferred by the same delay and does not use an attempt.
    func pollWriteBackStatus() async {
        var attempt = 0
        var lastContext = writeBackPollContext
        while attempt < Self.writeBackPollDelays.count, isAwaitingWriteBackCompletion {
            do {
                try await clock.sleep(for: Self.writeBackPollDelays[attempt])
            } catch {
                return
            }
            guard !Task.isCancelled, isAwaitingWriteBackCompletion else { return }
            if let lastContext, !contextValidator(lastContext) {
                return
            }
            guard !isBusy, !isPollingStatus else { continue }
            switch await pollStatusOnce() {
            case .deferred:
                continue
            case .stop:
                return
            case let .sent(context):
                attempt += 1
                lastContext = context
            }
        }
    }

    /// Waits until no background status poll request is in flight.
    func waitForStatusPoll() async {
        while isPollingStatus {
            await withCheckedContinuation { statusPollWaiters.append($0) }
        }
    }

    private enum PollResult {
        /// The gate refused the request; nothing was sent.
        case deferred
        case stop
        /// Keep polling from this context.
        case sent(DeckRequestContext)
    }

    /// Refreshes status without `isBusy`, so user controls stay enabled.
    private func pollStatusOnce() async -> PollResult {
        isPollingStatus = true
        defer {
            isPollingStatus = false
            let waiters = statusPollWaiters
            statusPollWaiters = []
            waiters.forEach { $0.resume() }
        }
        var context: DeckRequestContext?
        do {
            let current = try await tokenProvider()
            context = current
            try validate(current)
            try await updateStatus(current, priority: .background)
            // Every awaited deck opted out: nothing more will run for it.
            let stillEnabled = awaitingResolutionDeckIDs.contains {
                writeBackStatuses[$0]?.enabled == true
            }
            return stillEnabled ? .sent(current) : .stop
        } catch is ArkhamDBRequestGate.Busy {
            return .deferred
        } catch {
            guard !Self.stopsStatusPolling(error), let context else { return .stop }
            return .sent(context)
        }
    }

    private static func stopsStatusPolling(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError, GameLifecycleTokenAccessError.stale,
             DeckServiceError.sessionExpired, DeckServiceError.unexpectedStatus(404):
            return true
        case let DeckServiceError.arkhamDB(remote?):
            let unavailable: [ArkhamDBErrorCode] = [
                .disabled, .writeBackDisabled, .notLinked, .tokenExpired, .notFound,
            ]
            return unavailable.contains(remote.code)
        default:
            // A token failure (no request was sent) stops; other request failures use an
            // attempt and keep polling.
            return !(error is DeckServiceError)
        }
    }
}
