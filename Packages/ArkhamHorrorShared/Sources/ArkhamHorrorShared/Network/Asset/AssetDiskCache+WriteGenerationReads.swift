import Foundation

/// The read/cross-check/issuance primitives for `key`'s durable
/// write-generation counter — split out of
/// `AssetDiskCache+WriteGeneration.swift` purely to keep that file
/// within this package's `file_length` convention. Every member here
/// must only ever be called while the caller already holds this
/// instance's own ``SecureCacheDirectory/acquireExclusiveLock()``,
/// exactly like the sibling file's own members.
extension AssetDiskCache {
    /// Reads `key`'s current durable issuance-ticket counter (the highest
    /// ticket ever reserved for `key`, by any caller). Must only ever be
    /// called while the caller already holds this instance's
    /// ``SecureCacheDirectory/acquireExclusiveLock()``.
    ///
    /// A clean "does not exist" miss is `0` — a genuinely pristine key
    /// that has never had a ticket reserved for it has no prior value to
    /// compare against, and `0` is a safe baseline precisely because no
    /// counter for this key has ever been durably persisted to lose. Any
    /// *other* failure (a symlink/non-regular entry at this name, an
    /// oversized or unparsable value) is a hard, typed, fail-closed
    /// failure instead, since it means a real, previously persisted
    /// counter exists but could not be trusted, which must never silently
    /// default back to the same baseline a pristine key would also
    /// report.
    ///
    /// **Also cross-checked, every call, against `key`'s own currently
    /// applied disposition (``currentDispositionLocked(for:)``).** The
    /// `.gen` counter this reads and the `.applied`/disposition file are
    /// two separate durable files; only ``AssetDiskCache/removeAll()``
    /// ever legitimately deletes both together, always paired with a
    /// durable clear-epoch bump every stale token is independently and
    /// unconditionally rejected by regardless (see
    /// `SecureCacheDirectory+ClearEpoch.swift`). So "this key's
    /// disposition durably records ticket *N* > 0 (content, retiring, or
    /// tombstone — any of the three, since all three prove a ticket was
    /// genuinely issued and applied for this key at some point), but this
    /// key's own `.gen` file is missing or reports a value below *N*" can
    /// only mean the `.gen` file itself was independently lost or
    /// corrupted — never a legitimately pristine key — and must never
    /// silently collapse back to the same `0` baseline a truly pristine
    /// key reports: a delayed/replayed ticket reserved against that
    /// wrongly-reset baseline could otherwise satisfy
    /// ``AssetDiskCache/acceptToken(_:currentEpoch:currentIssued:)``'s own
    /// CAS and overwrite or retract content a strictly newer ticket
    /// already durably owns. Fails closed with a typed
    /// ``AssetError/cachePersistenceFailed(_:)`` instead, exactly like
    /// every other "a real, previously persisted value exists but could
    /// not be trusted" case this method already fails closed for.
    func currentIssuedTicketLocked(for key: AssetCacheKey) throws -> Int {
        let issued = try readTicketLocked(name: writeGenerationFilename(for: key))
        let appliedTicket = try currentDispositionLocked(for: key).ticket
        guard appliedTicket <= issued else {
            throw AssetError.cachePersistenceFailed(
                "Issuance counter for this key is missing or behind its own "
                    + "surviving disposition"
            )
        }
        return issued
    }

    /// Reads `key`'s current durable *applied* ticket — the ticket half
    /// of ``currentDispositionLocked(for:)``'s full typed disposition
    /// (see `AssetDiskCache+Disposition.swift`'s type-level doc comment).
    /// Must only ever be called while the caller already holds this
    /// instance's ``SecureCacheDirectory/acquireExclusiveLock()``. A
    /// clean "does not exist" miss is `0` for the identical reason
    /// ``currentIssuedTicketLocked(for:)``'s own is: a genuinely pristine
    /// key has nothing applied yet.
    func currentAppliedTicketLocked(for key: AssetCacheKey) throws -> Int {
        try currentDispositionLocked(for: key).ticket
    }

    /// A single, atomic, cross-instance/cross-process authority snapshot
    /// for `key` — the durable clear epoch and this key's own highest
    /// durably *issued* ticket, read together under one exclusive-lock
    /// acquisition. Used by
    /// ``AssetCacheService/memoryEntryStillCurrent(_:storedGeneration:for:)``
    /// to decide whether an already-cached memory entry is still safe to
    /// serve without re-validating.
    ///
    /// **Deliberately reads the highest *issued* ticket, never merely the
    /// highest *applied* one, and the two fields are read together under
    /// one lock hold rather than as two separate, independently-locked
    /// calls.** An earlier revision instead read
    /// ``currentDurableClearEpoch()`` and a separate
    /// ``currentAppliedTicket(for:)`` call one after the other, each its
    /// own independent lock acquisition/release — a torn read: a sibling
    /// instance/process's whole-cache clear landing in the window between
    /// those two separately-locked reads could leave this call observing
    /// a pre-clear epoch paired with a post-clear (or vice versa)
    /// applied ticket, neither half actually describing the same durable
    /// moment in time. Comparing only against the highest *applied*
    /// ticket has a second, independent defect: a sibling service/process
    /// can *issue* (durably reserve, via ``issueTicketLocked(for:)``) a
    /// fresh ticket for this exact key the moment it begins a
    /// fetch/revalidation, strictly *before* that operation's own
    /// eventual mutation actually lands and advances the *applied*
    /// counter -- during that whole window, an applied-ticket-only
    /// comparison would keep reporting an older memory entry "still
    /// current" even though a strictly newer, already-in-flight operation
    /// for this exact key has already been issued and may complete with
    /// entirely different content (or a definitive removal) at any
    /// moment. Comparing against the highest *issued* ticket instead, with
    /// exact equality (not `>=`), rejects a memory hit the instant *any*
    /// newer operation for this key has been issued anywhere, regardless
    /// of whether that operation has itself completed yet -- the
    /// strictest safe comparison, matching
    /// ``AssetDiskCache/acceptToken(_:currentEpoch:currentIssued:)``'s own
    /// per-key fencing semantics exactly.
    func currentKeyAuthority(for key: AssetCacheKey) async throws -> KeyAuthoritySnapshot {
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        let epoch = try secureDirectory.readPersistedClearEpoch()
        let issuedTicket = try currentIssuedTicketLocked(for: key)
        return KeyAuthoritySnapshot(clearEpoch: epoch, issuedTicket: issuedTicket)
    }

    /// The named result of ``currentKeyAuthority(for:)`` — see that
    /// method's own doc comment for why both fields must always be read
    /// together, under one lock hold, rather than as two independently
    /// re-readable values.
    struct KeyAuthoritySnapshot: Sendable, Equatable {
        let clearEpoch: Int
        let issuedTicket: Int
    }

    private func readTicketLocked(name: String) throws -> Int {
        guard let data = try secureDirectory.read(
            name: name,
            maxBytes: Self.ticketDigitWidth
        ) else {
            return 0
        }
        guard
            let string = String(data: data, encoding: .utf8),
            string.utf8.count == Self.ticketDigitWidth,
            string.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
            let parsed = Int(string)
        else {
            throw AssetError.cachePersistenceFailed(
                "Ticket file '\(name)' is corrupt or unparsable"
            )
        }
        return parsed
    }

    /// Durably reserves and returns a fresh ticket for `key`: reads the
    /// current issuance counter, durably commits its successor (write,
    /// `fsync`, rename, directory `fsync`), and returns that successor —
    /// never the pre-bump value. Called by ``beginIssuance(for:)`` (one
    /// reservation per logical operation's issuance) and by
    /// ``AssetDiskCache/resolvedMutationTicketLocked(for:token:)``'s own
    /// unconditional (`token: nil`) branch (one further reservation per
    /// actual committed mutation with no external token to reuse) alike:
    /// every single call to this method, from anywhere, returns a value
    /// no other call -- past, present, or future -- will ever return
    /// again for this key.
    ///
    /// Guards against overflow: once already at `Int.max`, throws rather
    /// than silently colliding two genuinely different future tickets
    /// onto the same value.
    func issueTicketLocked(for key: AssetCacheKey) throws -> Int {
        let current = try currentIssuedTicketLocked(for: key)
        guard current < Int.max else {
            throw AssetError.cachePersistenceFailed(
                "Write-generation counter is exhausted for this key"
            )
        }
        let next = current + 1
        try persistTicketLocked(next, name: writeGenerationFilename(for: key))
        return next
    }
}
