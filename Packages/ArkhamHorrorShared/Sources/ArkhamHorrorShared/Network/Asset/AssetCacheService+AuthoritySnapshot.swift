import Foundation

/// Read-only authority snapshot/compare helpers for `AssetCacheService`,
/// split out of `AssetCacheService+Epoch.swift` purely to keep that file
/// within this package's `file_length` convention.
extension AssetCacheService {
    /// A named, non-tuple result type for ``snapshotAuthority(for:)`` /
    /// ``unchanged(since:for:)`` — a plain 3-member tuple would trip this
    /// package's `large_tuple` lint convention, and a named type also
    /// documents each field's role once instead of relying on positional
    /// tuple-label repetition at every call site.
    struct AuthoritySnapshot: Equatable {
        let token: CacheToken?
        let generation: Int
        let clearGeneration: Int
    }

    /// A read-only snapshot of `key`'s current authority state, taken
    /// immediately *before* a disk read whose result must not be trusted
    /// if that authority changes while the read is suspended -- see
    /// ``unchanged(since:for:)``. Deliberately does **not** call
    /// ``issueToken(for:)``: a disk-hit lookup that turns out to be a
    /// miss, or whose read loses the race checked by
    /// ``unchanged(since:for:)``, must never have consumed an issuance
    /// number or clobbered whatever fetch is (or is about to be) legitimately
    /// in flight for this key -- unlike a snapshot, issuing a token is
    /// never a no-op: it unconditionally supersedes the current
    /// authoritative token for `key`, which would wrongly invalidate an
    /// already-in-flight coalesced fetch's own token merely because a
    /// second, ultimately-coalescing caller also happened to pass through
    /// this same disk-hit code path.
    ///
    /// Includes ``AssetCacheService/keyClearGeneration`` alongside
    /// `keyLatestToken`/`globalGeneration`: a single unified snapshot/
    /// compare pair used by *every* caller (an ordinary memory/disk hit
    /// and a revalidation's memory-hit branch alike), rather than two
    /// separate, subtly different checks — a design that previously let
    /// some callers miss an intervening invalidation entirely (see
    /// ``isAuthoritative(_:for:)``'s doc comment).
    func snapshotAuthority(for key: AssetCacheKey) -> AuthoritySnapshot {
        AuthoritySnapshot(
            token: keyLatestToken[key],
            generation: globalGeneration,
            clearGeneration: keyClearGeneration[key] ?? 0
        )
    }

    /// `true` only if `key`'s authority state is *exactly* what
    /// ``snapshotAuthority(for:)`` observed it to be, immediately before a
    /// disk read this call now wants to trust the result of. A mismatch
    /// means some other operation -- a more-recently-issued fetch or
    /// revalidation for this exact key, or a cache-wide ``evictAll()`` --
    /// became authoritative for this key while the read was suspended, so
    /// the read's result (even if it returned a value) must not be
    /// promoted into memory or used as the basis for a conditional
    /// request: see ``asset(for:)``'s and ``revalidate(for:)``'s own
    /// disk-hit branches.
    func unchanged(
        since snapshot: AuthoritySnapshot,
        for key: AssetCacheKey
    ) -> Bool {
        keyLatestToken[key] == snapshot.token
            && globalGeneration == snapshot.generation
            && (keyClearGeneration[key] ?? 0) == snapshot.clearGeneration
    }

    /// A narrower read-only snapshot of `key`'s *invalidation* state only
    /// — the whole-cache generation plus this key's own clear generation
    /// — deliberately omitting ``AssetCacheService/keyLatestToken``.
    ///
    /// Used exclusively by ``revalidate(for:)``'s memory-hit branch: that
    /// branch's own subsequent call into ``revalidateExisting(_:key:cacheKey:candidates:)``
    /// is coalesced through ``coalescedRevalidation(existing:key:cacheKey:candidates:)``'s
    /// in-flight dictionary, so a second, concurrent, otherwise-identical
    /// `revalidate(for:)` call for the very same key legitimately
    /// observes a *different* ``keyLatestToken`` the moment the first
    /// call's own coalesced revalidation has issued its shared token —
    /// that is the intended coalescing outcome, not staleness, and must
    /// not itself defeat the second call's memory hit. What *would*
    /// genuinely invalidate this memory hit is an actual clear: either an
    /// individual ``invalidate(_:token:)`` for this key (bumps
    /// ``AssetCacheService/keyClearGeneration``) or a cache-wide
    /// ``evictAll()`` (bumps ``AssetCacheService/globalGeneration``) —
    /// both of which this narrower pair still observes. Every other
    /// call site (plain memory/disk hits in ``asset(for:)``, and
    /// `revalidate(for:)`'s own disk-hit branch, neither of which is
    /// behind any coalescing dictionary) continues to use the broader
    /// ``snapshotAuthority(for:)``/``unchanged(since:for:)`` pair.
    func snapshotClearState(for key: AssetCacheKey) -> (generation: Int, clearGeneration: Int) {
        (globalGeneration, keyClearGeneration[key] ?? 0)
    }

    /// `true` only if `key`'s *invalidation* state is exactly what
    /// ``snapshotClearState(for:)`` observed it to be — see that method's
    /// doc comment for why this intentionally ignores
    /// ``AssetCacheService/keyLatestToken`` churn from a legitimately
    /// coalescing concurrent operation for the same key.
    func clearStateUnchanged(
        since snapshot: (generation: Int, clearGeneration: Int),
        for key: AssetCacheKey
    ) -> Bool {
        globalGeneration == snapshot.generation
            && (keyClearGeneration[key] ?? 0) == snapshot.clearGeneration
    }
}
