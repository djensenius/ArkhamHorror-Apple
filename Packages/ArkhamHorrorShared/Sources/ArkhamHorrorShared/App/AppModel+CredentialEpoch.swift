import Foundation

/// Per-profile and service-wide credential-epoch bookkeeping and serialized
/// token-store access. Durable cancellation-cleanup tombstone reservation/resolution
/// built on top of this lives in ``AppModel+CleanupReservation.swift``.
///
/// Split out of `AppModel.swift` purely by file size; every member here operates on
/// exactly the same `@MainActor`-isolated state declared there (``AppModel/credentialEpochs``,
/// ``AppModel/globalCredentialEpoch``, ``AppModel/serviceResetBarrier``, and
/// ``AppModel/tokenAccessQueues``) and is documented together with them there.
extension AppModel {
    /// Serializes a durable ``TokenStore`` read, save, or delete for `profileID` behind
    /// any earlier one for the same profile that is still in flight, only actually
    /// running `operation` if `epoch` still matches ``credentialEpochs`` for
    /// `profileID`, and `globalEpoch` still matches ``globalCredentialEpoch``, at the
    /// instant it is about to run — also awaiting an active ``serviceResetBarrier``, if
    /// any is present at that instant, first.
    ///
    /// A generation check performed only before enqueueing, or only after an awaited
    /// call returns, is not enough to keep the token store itself consistent with the
    /// profile's *current* endpoint: an in-flight save may already be queued behind an
    /// endpoint edit's or removal's delete by the time that edit/removal invalidates
    /// the profile's credential epoch, so a generation check made when the save was
    /// *enqueued* can never observe that later invalidation. `epoch` must therefore be
    /// captured once, by the caller, at the same point its ``AppModel/generation`` is
    /// captured (operation start), and threaded through unchanged; this function then
    /// rechecks it against the live epoch immediately before `operation` runs — the
    /// last possible moment before the Keychain is actually touched — so an
    /// already-enqueued stale save can never durably resurrect a token for a
    /// since-changed or since-removed endpoint. The same reasoning applies to
    /// `globalEpoch` against a service-wide storage reset (``confirmStorageReset()``):
    /// capturing it once, at the same moment as `epoch`, and rechecking it here
    /// guarantees a reset that begins after this operation started — even one whose
    /// own drain-then-wipe sequence this operation ends up queued behind — is never
    /// raced by a save this operation was already committed to making. On either
    /// mismatch, `operation` is skipped and ``StaleCredentialEpochError`` is thrown;
    /// every call site treats this exactly like ``CancellationError`` (never surfaced
    /// as a user-facing failure).
    ///
    /// Beyond credential-epoch safety, this also preserves the existing ordering
    /// guarantee: durable mutations for a profile always apply in the order they were
    /// requested, and any later read for that profile always observes the effect of an
    /// earlier, still in-flight mutation rather than a stale value. Reads and writes
    /// for different profiles remain fully independent.
    @discardableResult
    func serializedTokenAccess<Value: Sendable>(
        for profileID: UUID,
        epoch: Int,
        globalEpoch: Int,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let previous = tokenAccessQueues[profileID]?.task
        // Captured synchronously, here — not dynamically re-read as `self
        // .serviceResetBarrier` inside the task body below — so this operation is
        // admitted exactly once, atomically with every other synchronous step in this
        // function, before any `await` can let a reset install a new barrier in
        // between. See the extended rationale on ``serviceResetBarrier`` itself.
        let admittedBarrier = serviceResetBarrier
        let scheduled = Task<Value, any Error> {
            await previous?.value
            if let admittedBarrier {
                await admittedBarrier.task.value
            }
            guard self.credentialEpochs[profileID, default: 0] == epoch,
                  self.globalCredentialEpoch == globalEpoch
            else {
                throw StaleCredentialEpochError()
            }
            return try await operation()
        }
        let tailID = UUID()
        let tail = Task { _ = try? await scheduled.value }
        tokenAccessQueues[profileID] = TokenAccessTail(id: tailID, task: tail)
        tokenAccessAdmissionHook?(profileID)
        defer {
            if tokenAccessQueues[profileID]?.id == tailID {
                tokenAccessQueues[profileID] = nil
            }
        }
        return try await scheduled.value
    }

    /// The current credential epoch for `profileID` (`0` if never invalidated), for a
    /// caller to capture once at the start of an operation alongside ``generation``.
    func currentCredentialEpoch(for profileID: UUID) -> Int {
        credentialEpochs[profileID, default: 0]
    }

    /// The current service-wide credential epoch, for a caller to capture once at the
    /// start of an operation alongside ``currentCredentialEpoch(for:)`` and
    /// ``generation``.
    func currentGlobalCredentialEpoch() -> Int {
        globalCredentialEpoch
    }

    /// Advances the credential epoch for `profileID` and returns the new value.
    ///
    /// Must be called synchronously, before enqueueing the delete that follows from
    /// the same invalidating event (an endpoint edit, a profile removal, a storage
    /// reset, or an explicit auth cancellation), so that no already-in-flight or
    /// not-yet-enqueued operation captured before this call can observe the new value
    /// as if it were its own — every other in-flight operation for this profile must
    /// have captured its epoch strictly earlier, and will therefore fail its recheck.
    @discardableResult
    func invalidateCredentialEpoch(for profileID: UUID) -> Int {
        let next = credentialEpochs[profileID, default: 0] + 1
        credentialEpochs[profileID] = next
        return next
    }
}
