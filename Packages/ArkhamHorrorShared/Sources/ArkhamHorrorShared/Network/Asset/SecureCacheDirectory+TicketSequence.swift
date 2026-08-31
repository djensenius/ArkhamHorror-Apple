import Foundation

/// A single, durable, cross-instance/cross-process **globally** monotonic
/// ticket counter, shared by *every* key any ``AssetDiskCache`` directory
/// ever issues a mutation ticket for -- introduced to close this review
/// round's finding #3 ("no ticket reuse after compaction").
///
/// Every prior revision of this cache's per-key issuance
/// (`AssetDiskCache+WriteGenerationReads.swift`'s `issueTicketLocked(for:)`)
/// derived a fresh ticket from *that key's own* current highest-issued
/// value (`current.issuedTicket + 1`) -- which is exactly what made
/// forgetting (compacting away) a settled key's own durable history
/// unsafe: once that key's own record is gone, "the next ticket" has
/// nothing left to be measured relative to, and a fresh issuance for the
/// same key could restart back at `1`, silently colliding with a ticket
/// this cache already handed out (and some caller may still legitimately
/// hold) before that history was forgotten.
///
/// Drawing every ticket -- for every key, cache-directory-wide -- from
/// this one, single, ever-increasing counter instead removes that
/// dependency entirely: uniqueness no longer depends on remembering any
/// specific key's own past, only on this counter itself never handing out
/// the same value twice, which it already guarantees unconditionally (see
/// ``allocateGlobalTicket()``). Forgetting (or never having recorded)
/// *any* key's own prior ticket is therefore always safe -- a *future*
/// reissuance for that exact key is guaranteed, by construction, to
/// receive a value strictly greater than every ticket this whole
/// directory has ever handed out before, including whatever value that
/// key's own now-forgotten history once held.
///
/// Bound to the durable clear epoch exactly like
/// ``SecureCacheDirectory/accessSequenceFileName``'s own counter is
/// *not*: unlike that counter (which must survive a clear so cross-
/// instance LRU ordering is never violated), this one is deliberately
/// **not** in ``AssetDiskCache/removeAll()``'s own reserved-name set --
/// every ticket issued before a real clear is already unconditionally
/// fenced by that clear's own epoch bump (``SecureCacheDirectory/bumpClearEpoch()``),
/// regardless of its own numeric value, so there is no correctness
/// requirement for this counter to keep counting up across a clear; a
/// fresh restart back at `1` afterward is both safe and desirable (an
/// unbounded counter that survived forever would otherwise be the one
/// remaining piece of durable state in this whole subsystem that could
/// never itself be reset).
extension SecureCacheDirectory {
    /// The fixed leaf name of this cache directory's durable, global
    /// ticket-sequence counter file. Not reserved across
    /// ``AssetDiskCache/removeAll()`` -- see this type's own doc comment
    /// for why resetting it on a real clear is safe.
    static let ticketSequenceFileName = ".arkham-cache.ticket-seq"

    /// Matches ``clearEpochDigitWidth``'s own fixed width and reasoning:
    /// generous headroom above `Int.max`'s own digit count, while still
    /// bounding a read against a tampered or corrupt file of unbounded
    /// size.
    static let ticketSequenceDigitWidth = 20

    /// Durably reserves and returns this cache directory's next globally
    /// unique ticket -- never a value any earlier or later call, for any
    /// key, will ever return again for the lifetime of the current clear
    /// epoch. Must only ever be called while the caller already holds
    /// this instance's ``acquireExclusiveLock()``.
    ///
    /// **Terminal saturation, never silent reuse or wraparound.** Once
    /// the persisted value is already `Int.max`, this throws rather than
    /// returning a value some earlier call already returned -- mirrors
    /// ``bumpClearEpoch()``'s identical terminal-saturation contract, for
    /// the identical reason: two genuinely different tickets must never
    /// collapse onto the same value.
    func allocateGlobalTicket() throws -> Int {
        let persisted = readPersistedTicketSequence() ?? 0
        guard persisted < Int.max else {
            throw AssetError.cachePersistenceFailed(
                "Global ticket sequence is exhausted for this cache directory; refusing to " +
                    "reuse a ticket value some earlier caller may still legitimately hold"
            )
        }
        let next = persisted + 1
        try persistTicketSequence(next)
        return next
    }

    /// Reads the currently persisted counter value, or `nil` if the file
    /// does not exist yet (a freshly created or freshly cleared cache
    /// root) or cannot be parsed as a valid, fixed-width, non-negative
    /// integer (a corrupt or foreign file somehow planted at this exact
    /// name) -- either case folds into the same "start counting from
    /// zero" baseline ``allocateGlobalTicket()`` already treats a missing
    /// file as. Unlike the durable clear-epoch counter, a corrupt/missing
    /// value here is *not*, by itself, a fail-closed condition: this
    /// counter existing purely to hand out *fresh* values that have never
    /// been used before, restarting it low can only ever under-count, and
    /// under-counting is made harmless by a *different*, independent
    /// invariant every caller of ``allocateGlobalTicket()`` itself
    /// upholds -- see ``AssetDiskCache/issueTicketLocked(for:)``'s own
    /// doc comment: that method never trusts a freshly allocated ticket
    /// on faith, it *requires* the newly allocated value to exceed this
    /// specific key's own already-known highest ticket (read fresh, via
    /// the key's own durable authority record/floor index -- state this
    /// counter's own corruption or loss has no effect on whatsoever) and
    /// fails closed for that one key if it does not. A key with no prior
    /// history accepts any freshly allocated value startin from `1`; a
    /// key with real prior history is protected by that *separate* check
    /// regardless of what this counter itself currently reads back as.
    func readPersistedTicketSequence() -> Int? {
        guard let data = try? read(
            name: Self.ticketSequenceFileName,
            maxBytes: Self.ticketSequenceDigitWidth
        ), let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        guard string.utf8.count == Self.ticketSequenceDigitWidth,
              string.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
              let parsed = Int(string)
        else {
            return nil
        }
        return parsed
    }

    private func persistTicketSequence(_ value: Int) throws {
        precondition(value >= 0, "Global ticket sequence must never be negative, got \(value)")
        let tempName = Self.ticketSequenceFileName + ".tmp"
        let raw = String(value)
        let padded = String(repeating: "0", count: Self.ticketSequenceDigitWidth - raw.count) + raw
        try writeTempAndFsync(tempName: tempName, data: Data(padded.utf8))
        try renameAndFsyncDirectory(from: tempName, to: Self.ticketSequenceFileName)
    }
}
