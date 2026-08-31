import Foundation

/// Applied-ticket commit operations for ``AssetDiskCache``, split out of
/// `AssetDiskCache+WriteGeneration.swift` purely to stay under this
/// package's file-length limit. See that file for the durable
/// issuance/applied ticket model these commit paths close over.
extension AssetDiskCache {
    /// Reserves a brand-new ticket for `key` (via ``issueTicketLocked(for:)``)
    /// and immediately durably commits it as `key`'s new applied ticket.
    /// Used only for an *unconditional* mutation (`token: nil` — direct
    /// actor access, or ``AssetDiskCache/removeAll()``'s own per-key
    /// counter handling is separate) that has no already-issued ticket of
    /// its own to commit: without reserving a fresh one here, an
    /// unconditional removal would leave `key`'s applied ticket exactly
    /// where it already was, letting a *later* replay of a token issued
    /// *before* this removal still satisfy `>=` against that unchanged
    /// value. A freshly reserved ticket is, by construction, always
    /// strictly greater than whatever was previously applied, so this
    /// unconditionally advances `key`'s applied ticket past every ticket
    /// ever issued up to and including this exact call.
    ///
    /// See ``commitAppliedTicketLocked(_:for:)`` for the token-gated
    /// counterpart used instead whenever a real, already-issued ticket
    /// exists to commit — the two must never be conflated (see that
    /// method's own doc comment for why).
    @discardableResult
    func reserveAndCommitMutationTicketLocked(for key: AssetCacheKey) throws -> Int {
        let ticket = try issueTicketLocked(for: key)
        try persistTicketLocked(ticket, name: appliedTicketFilename(for: key))
        return ticket
    }

    /// Durably commits `ticket` — the *exact* value a token-gated
    /// operation's own ``AssetCacheService/CacheToken/diskWriteGeneration``
    /// already carries from its own issuance — as `key`'s new applied
    /// ticket, without reserving any further, different value.
    ///
    /// **Must never instead call ``reserveAndCommitMutationTicketLocked(for:)``
    /// for a token-gated commit.** That method mints a *brand-new* ticket
    /// distinct from whatever the caller's own token carries — which
    /// would durably commit a value the token itself never actually
    /// carries, so a later retraction of that exact same token/mutation
    /// (``AssetDiskCache/removeIfApplied(_:token:)``, whose own contract
    /// is deliberately an *exact* match against `token`'s own issued
    /// ticket — never `AssetDiskCache/acceptToken(_:currentEpoch:currentApplied:)``'s
    /// `>=`) could never again find `currentApplied == token`'s own
    /// ticket, since the actually-applied value would already have moved
    /// one step past it. Committing the token's own already-checked
    /// ticket verbatim instead keeps the applied counter's value in exact
    /// lockstep with whichever token's mutation most recently landed —
    /// still always monotonically non-decreasing, since
    /// ``AssetDiskCache/acceptToken(_:currentEpoch:currentApplied:)`` only
    /// ever accepts a token whose own ticket is already `>=` the value
    /// this then commits.
    func commitAppliedTicketLocked(_ ticket: Int, for key: AssetCacheKey) throws {
        try persistTicketLocked(ticket, name: appliedTicketFilename(for: key))
    }

    /// Commits the correct applied ticket for a just-completed mutation on
    /// `key`, dispatching to whichever of ``commitAppliedTicketLocked(_:for:)``/
    /// ``reserveAndCommitMutationTicketLocked(for:)`` applies: a token-gated
    /// call already carries its own issued ticket (already accepted by
    /// ``AssetDiskCache/acceptToken(_:currentEpoch:currentApplied:)`` before
    /// this runs) and must commit *exactly* that value; an unconditional
    /// (`token: nil`) call has no ticket of its own and must instead
    /// reserve a brand-new one. Every actually-committing mutation
    /// (``AssetDiskCache/set(_:payload:metadata:token:)``,
    /// ``AssetDiskCache/touch(_:metadata:token:)``,
    /// ``AssetDiskCache/remove(_:token:)``) calls this immediately before
    /// its own durable write/removal takes effect.
    @discardableResult
    func commitMutationTicketLocked(
        for key: AssetCacheKey,
        token: AssetCacheService.CacheToken?
    ) throws -> Int {
        if let ticket = token?.diskWriteGeneration {
            try commitAppliedTicketLocked(ticket, for: key)
            return ticket
        }
        return try reserveAndCommitMutationTicketLocked(for: key)
    }

    func persistTicketLocked(_ value: Int, name: String) throws {
        precondition(value >= 0, "A ticket must never be negative")
        let raw = String(value)
        let padded = String(repeating: "0", count: Self.ticketDigitWidth - raw.count) + raw
        let tempName = name + ".tmp"
        try secureDirectory.writeTempAndFsync(tempName: tempName, data: Data(padded.utf8))
        try secureDirectory.renameAndFsyncDirectory(from: tempName, to: name)
    }
}
