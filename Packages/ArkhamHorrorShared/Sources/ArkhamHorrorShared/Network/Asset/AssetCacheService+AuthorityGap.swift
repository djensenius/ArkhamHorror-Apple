import Foundation

extension AssetCacheService {
    /// Records `authorityID` as the newest authority this process has
    /// issued for `key`, in issuance order — the sole writer of
    /// ``issuedAuthorityChain``.
    ///
    /// Called by ``beginIssuance(for:)`` and by this actor's own
    /// `beginRevalidationIssuance(for:historicalClearEpoch:...)`
    /// — the only two places this actor ever obtains a freshly minted
    /// identifier — at the exact moment each one succeeds. Capped at
    /// ``maxRetiringGapWalk`` `+ 1` entries per key
    /// (oldest dropped first): the walk below never looks further back
    /// than that anyway, so retaining more would be pure growth for no
    /// reachable benefit.
    func noteAuthorityIssued(_ authorityID: AuthorityID?, for key: AssetCacheKey) {
        guard let authorityID else { return }
        var chain = issuedAuthorityChain[key] ?? []
        chain.append(authorityID)
        if chain.count > Self.maxRetiringGapWalk + 1 {
            chain.removeFirst(chain.count - (Self.maxRetiringGapWalk + 1))
        }
        issuedAuthorityChain[key] = chain
    }

    /// `true` if `issuedAuthorityID` (``AssetDiskCache/KeyAuthoritySnapshot/issuedAuthorityID``,
    /// `key`'s current durable most-recently-issued identifier) is
    /// exactly `storedAuthorityID`, **or** every authority this process
    /// issued for `key` after `storedAuthorityID`, up to and including
    /// `issuedAuthorityID`, has already been durably decided — via
    /// ``markGenerationRetiring(_:for:)`` — to be retracted, and can
    /// therefore never legitimately apply a mutation for `key` at all.
    ///
    /// Closes a gap a plain `storedAuthorityID == issuedAuthorityID`
    /// equality check leaves open: issuing an authority for `key` —
    /// minted the instant a fresh fetch/revalidation begins, strictly
    /// *before* it is known whether that operation will ever complete —
    /// durably replaces `issuedAuthorityID` immediately, even if that
    /// exact operation is cancelled (by its sole waiter leaving) before
    /// it ever reaches a `publish`/`touch`/`invalidate` call. A plain
    /// equality check would then treat *every* still-genuinely-current
    /// entry as permanently stale the instant any later operation for the
    /// same key is merely issued and abandoned — forcing every subsequent
    /// read through a live disk-hit-then-mandatory-online-revalidation
    /// path for content that never actually changed, even while that
    /// network round trip may be genuinely unreachable.
    ///
    /// **Walks this process's own recorded issuance chain, because random
    /// identifiers cannot be enumerated arithmetically.** The predecessor
    /// design counted integer tickets downward from the current one; with
    /// unordered 128-bit identifiers there is no "next lower" value to
    /// visit, so the walk instead follows ``issuedAuthorityChain`` — the
    /// exact order this process issued them in. That is strictly more
    /// conservative than the arithmetic walk it replaces: an identifier
    /// this process never issued (a sibling process's, or one aged out of
    /// the chain cap) is simply absent, and this returns `false`, exactly
    /// as the arithmetic walk already did for any ticket it had no
    /// retiring record for.
    ///
    /// Fail-closed at every step: the instant any authority in the gap is
    /// *not* confirmed-retiring — because it is still genuinely in
    /// flight, or because it already applied a real mutation — this
    /// returns `false`, since that operation could still (or already
    /// does) carry different content for `key`. Only a gap of
    /// *exclusively* confirmed-dead authorities lets the older,
    /// still-unretracted entry keep being served.
    ///
    /// Not `private`: also used by
    /// `AssetCacheService+WaiterAcknowledgement.swift`'s
    /// `isTokenAuthoritative(_:for:currentAuthority:)`, which applies this
    /// same tolerance to a coalesced operation's own final
    /// waiter-delivery decision, not only to a memory-hit re-validation.
    func authorityGapIsEntirelyAbandoned(
        from issuedAuthorityID: AuthorityID,
        downTo storedAuthorityID: AuthorityID,
        epoch: Int,
        for key: AssetCacheKey
    ) -> Bool {
        guard issuedAuthorityID != storedAuthorityID else { return true }
        guard
            let chain = issuedAuthorityChain[key],
            let storedIndex = chain.lastIndex(of: storedAuthorityID),
            let issuedIndex = chain.lastIndex(of: issuedAuthorityID),
            issuedIndex > storedIndex,
            issuedIndex - storedIndex <= Self.maxRetiringGapWalk
        else {
            return false
        }
        let intermediate = chain[(storedIndex + 1) ... issuedIndex]
        for candidate in intermediate {
            guard authorityIsRetiring(candidate, epoch: epoch, for: key) else { return false }
        }
        return true
    }
}

extension AssetCacheService {
    /// A durable-clear-epoch-scoped ``AuthorityID`` -- see
    /// ``AssetCacheService/retiringGenerations``'s own doc comment.
    /// Scoping to the epoch the retraction decision was made under keeps
    /// this bookkeeping aligned with the durable fence a whole-cache
    /// clear establishes: entries stamped under a superseded epoch are
    /// already rejected wholesale by every caller's own epoch comparison,
    /// so a retiring record from a prior epoch can never be consulted
    /// against a post-clear entry.
    struct RetiringAuthority: Hashable, Sendable {
        let epoch: Int
        let authorityID: AuthorityID
    }
}
