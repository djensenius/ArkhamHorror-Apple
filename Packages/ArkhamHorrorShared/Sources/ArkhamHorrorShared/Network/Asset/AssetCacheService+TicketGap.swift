import Foundation

extension AssetCacheService {
    /// `true` if `issuedTicket` (``AssetDiskCache/KeyAuthoritySnapshot/issuedTicket``,
    /// `key`'s current durable highest-issued ticket) is exactly
    /// `storedGeneration`, **or** every ticket in `(storedGeneration, issuedTicket]`
    /// — that is, `issuedTicket` itself and every ticket strictly between it
    /// and `storedGeneration` — has already been durably decided, via
    /// ``markGenerationRetiring(_:for:)``, to be retracted and therefore can
    /// never legitimately apply a mutation for `key` at all.
    ///
    /// Closes a gap ``memoryEntryStillCurrent(_:storedGeneration:for:)``'s
    /// prior plain `storedGeneration == currentAuthority.issuedTicket`
    /// equality check left open: issuing a ticket for `key` — reserved
    /// the instant a fresh fetch/revalidation begins, strictly *before*
    /// it is known whether that operation will ever complete — advances
    /// `currentAuthority.issuedTicket` immediately, even if that exact
    /// operation is cancelled (by its sole waiter leaving) before it ever
    /// reaches a `publish`/`touch`/`invalidate` call. A plain equality
    /// check would then treat *every* still-genuinely-current entry as
    /// permanently stale the instant any later operation for the same
    /// key is merely issued and abandoned — forcing every subsequent
    /// read through a live disk-hit-then-mandatory-online-revalidation
    /// path for content that never actually changed, even while that
    /// network round trip may be genuinely unreachable (e.g. cancelled
    /// mid-flight against a still-held transport in a test, or a
    /// genuinely offline network).
    ///
    /// Walking strictly *downward* from the highest issued ticket keeps
    /// this fail-closed: the instant any ticket in the gap is *not*
    /// confirmed-retiring — because it is still genuinely in flight, or
    /// because it already applied a real mutation — this returns `false`
    /// exactly as the original equality check would have, since that
    /// ticket could still (or already does) carry different content for
    /// `key`. Only a gap of *exclusively* confirmed-dead tickets lets the
    /// older, still-unretracted entry keep being served.
    ///
    /// Bounded at ``AssetCacheService/maxRetiringGapWalk`` purely as a
    /// defensive ceiling on this one key's own gap (ticket numbers are
    /// strictly increasing per key — see
    /// `AssetDiskCache+WriteGeneration.swift` — so this can only ever
    /// grow from genuinely distinct issue-then-abandon cycles for this
    /// *same* key, never from unrelated cache activity): a gap wider
    /// than that ceiling fails closed rather than performing an
    /// unbounded walk. Not `private`: also used by
    /// `AssetCacheService+WaiterAcknowledgement.swift`'s
    /// `isTokenAuthoritative(_:for:currentAuthority:)`, which applies
    /// this same tolerance to a coalesced operation's own final
    /// waiter-delivery decision, not only to a memory-hit re-validation.
    func ticketGapIsEntirelyAbandoned(
        from issuedTicket: Int,
        downTo storedGeneration: Int,
        epoch: Int,
        for key: AssetCacheKey
    ) -> Bool {
        guard issuedTicket != storedGeneration else { return true }
        guard issuedTicket > storedGeneration else { return false }
        guard issuedTicket - storedGeneration <= Self.maxRetiringGapWalk else { return false }
        var candidate = issuedTicket
        while candidate > storedGeneration {
            guard writeGenerationIsRetiring(candidate, epoch: epoch, for: key) else { return false }
            candidate -= 1
        }
        return true
    }
}
