import Foundation

/// The durable, cross-instance/cross-process per-key **issuance** and
/// **applied** ticket counters for `AssetDiskCache` — the disk-side half
/// of the compare-and-swap that closes this package's most persistently-
/// flagged review finding: a purely actor-local (in-memory) applied-token
/// dictionary cannot tell two *independent* `AssetCacheService`/
/// `AssetDiskCache` instances (two OS processes, or two independently
/// constructed instances in one process, each pointed at this same
/// on-disk directory) apart at all — each keeps its own private in-memory
/// state, so an older instance's delayed write/removal has no way to
/// learn a newer instance already concluded for the exact same key, and
/// vice versa.
///
/// **Two separate durable counters per key, not one.** An earlier
/// revision of this mechanism used a single counter file, read (never
/// reserved) at issuance time and compared for *exact* equality at
/// publish time. That is completion-ordered, not issuance-ordered: two
/// operations issued at nearly the same moment, before either has
/// published, both read the *same* current value (nothing has changed
/// yet), so whichever one happens to *complete* first "wins" the
/// equality check and advances the counter — and the other, genuinely
/// issued *after* it, then finds the counter has moved past its own
/// stale snapshot and is wrongly rejected, even though it should be the
/// one to win. This revision instead keeps:
///
/// - ``issueTicketLocked(for:)`` (called by ``beginIssuance(for:)``):
///   durably reserves a fresh, strictly-increasing, never-reused ticket
///   for `key` the moment an operation is *issued* — before it ever
///   suspends for network I/O or a decode — so two concurrently-issued
///   operations for the same key always receive two distinct,
///   totally-ordered tickets, never the same snapshot value.
/// - ``currentAppliedTicketLocked(for:)``/``reserveAndCommitMutationTicketLocked(for:)``:
///   a *separate* durable counter recording the highest ticket any
///   mutation for `key` has actually committed (published, touched, or
///   removed) — compared with `>=`, not `==`, against an operation's own
///   issued ticket in ``AssetDiskCache/acceptToken(_:currentEpoch:currentApplied:)``.
///   A higher-ticketed (later-issued) operation always outranks a
///   lower-ticketed one regardless of which one's network round trip or
///   decode happens to finish first; an operation whose own ticket is no
///   longer the highest ever applied is unconditionally stale.
///
/// Both counters live entirely separate from the key's
/// ``AssetCacheMetadata`` sidecar: that sidecar is deleted the instant a
/// key's entry is definitively removed (a 404 invalidation, a failed
/// re-validation quarantine), and reusing either counter's storage there
/// would let "no entry currently exists" collapse back to the exact same
/// baseline value (`0`) an operation issued *before this key had ever
/// been written at all* also captured — indistinguishable from a
/// genuinely pristine key, and so wrongly able to resurrect content
/// after a legitimate removal if that very first, still-suspended
/// operation's own response happens to arrive after both a full write and
/// a subsequent removal have already completed for the same key. Neither
/// counter file is ever deleted by an ordinary per-key
/// ``AssetDiskCache/remove(_:token:)`` — only ``AssetDiskCache/removeAll()``
/// (which is always paired with a durable clear-epoch bump any stale
/// token is independently and unconditionally rejected by; see
/// `SecureCacheDirectory+ClearEpoch.swift`) ever removes them, so a key's
/// write-ordering history survives an ordinary content removal exactly as
/// long as it needs to.
///
/// Every successful mutation (``AssetDiskCache/set(_:payload:metadata:token:)``,
/// ``AssetDiskCache/touch(_:metadata:token:)``, ``AssetDiskCache/remove(_:token:)``)
/// — even one called with no external `token` at all (test-only direct
/// actor access) — reserves and commits its *own* fresh ticket via
/// ``reserveAndCommitMutationTicketLocked(for:)`` immediately before it
/// actually mutates disk state, and that freshly reserved ticket (always
/// strictly greater than whatever was previously applied, by
/// construction: a ticket is only ever reserved by bumping the same
/// monotonic counter ``issueTicketLocked(for:)`` itself draws from)
/// becomes the new applied value. This is what makes even an
/// *unconditional* removal (no `token` supplied) permanently and
/// correctly reject a later replay of a `token` issued before that
/// removal: the replayed token's own ticket can never again be `>=` the
/// applied ticket that removal itself just committed.
extension AssetDiskCache {
    private static let ticketDigitWidth = 20

    /// The fixed leaf name of `key`'s durable issuance-ticket counter
    /// file — the source of every fresh ticket ever reserved for `key`,
    /// via ``issueTicketLocked(for:)`` alike. Key-hash-derived only
    /// (never from any other input), so it is always a single,
    /// traversal-proof leaf name, exactly like
    /// ``metadataFilename(for:)``/``payloadFilename(keyHash:contentHash:)``.
    func writeGenerationFilename(for key: AssetCacheKey) -> String {
        "\(key.digestHex).gen"
    }

    /// The fixed leaf name of `key`'s durable *applied* ticket counter
    /// file — the highest ticket any mutation for `key` has actually
    /// committed, compared with `>=` against an operation's own issued
    /// ticket by ``AssetDiskCache/acceptToken(_:currentEpoch:currentApplied:)``.
    func appliedTicketFilename(for key: AssetCacheKey) -> String {
        "\(key.digestHex).applied"
    }

    /// A single, atomic, cross-instance/cross-process issuance snapshot
    /// for `key`: the durable clear epoch and a freshly reserved,
    /// strictly-increasing, never-reused ticket for this key's own
    /// durable issuance counter, read/reserved together under one
    /// exclusive-lock acquisition. Called exactly once, as the very first
    /// step of issuing a fresh (never coalesced-into) fetch/revalidation/
    /// disk-hit operation — *before* the synchronous "check the
    /// coalescing dictionary, else create and issue" decision that
    /// follows it (see `AssetCacheService+Coalescing.swift`/
    /// `AssetCacheService+Revalidation.swift`) — so the resulting
    /// ``AssetCacheService/CacheToken`` can be fully stamped,
    /// synchronously, at the moment it is actually issued, rather than
    /// being restamped later from a value re-read after an unrelated
    /// suspension (the exact TOCTOU gap a prior review specifically
    /// flagged: "durable epoch captured after operation issuance").
    ///
    /// Unlike a prior revision, this *reserves* (durably bumps) the
    /// ticket rather than merely reading the current value: two
    /// operations issued concurrently, before either has published, now
    /// always receive two distinct, totally-ordered tickets — never the
    /// same snapshot — which is what lets a later-issued operation always
    /// outrank an earlier-issued one regardless of completion order (see
    /// this file's own type-level doc comment).
    ///
    /// Throws (fail closed) on any read/write failure for either value —
    /// callers treat a failed snapshot identically to an unstamped token:
    /// permanently non-authoritative, never a silent default.
    struct IssuanceSnapshot: Sendable {
        let clearEpoch: Int
        let writeGeneration: Int
    }

    func beginIssuance(for key: AssetCacheKey) async throws -> IssuanceSnapshot {
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        recoverOrphansIfNeeded()
        let epoch = try secureDirectory.readPersistedClearEpoch()
        let ticket = try issueTicketLocked(for: key)
        return IssuanceSnapshot(clearEpoch: epoch, writeGeneration: ticket)
    }

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
    func currentIssuedTicketLocked(for key: AssetCacheKey) throws -> Int {
        try readTicketLocked(name: writeGenerationFilename(for: key))
    }

    /// Reads `key`'s current durable *applied* ticket — the highest
    /// ticket any mutation for `key` has actually committed. Must only
    /// ever be called while the caller already holds this instance's
    /// ``SecureCacheDirectory/acquireExclusiveLock()``. A clean "does not
    /// exist" miss is `0` for the identical reason
    /// ``currentIssuedTicketLocked(for:)``'s own is: a genuinely pristine
    /// key has nothing applied yet.
    func currentAppliedTicketLocked(for key: AssetCacheKey) throws -> Int {
        try readTicketLocked(name: appliedTicketFilename(for: key))
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
    /// ``reserveAndCommitMutationTicketLocked(for:)`` (one further
    /// reservation per actual committed mutation) alike: every single
    /// call to this method, from anywhere, returns a value no other call
    /// -- past, present, or future -- will ever return again for this
    /// key.
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

    private func persistTicketLocked(_ value: Int, name: String) throws {
        precondition(value >= 0, "A ticket must never be negative")
        let raw = String(value)
        let padded = String(repeating: "0", count: Self.ticketDigitWidth - raw.count) + raw
        let tempName = name + ".tmp"
        try secureDirectory.writeTempAndFsync(tempName: tempName, data: Data(padded.utf8))
        try secureDirectory.renameAndFsyncDirectory(from: tempName, to: name)
    }
}
