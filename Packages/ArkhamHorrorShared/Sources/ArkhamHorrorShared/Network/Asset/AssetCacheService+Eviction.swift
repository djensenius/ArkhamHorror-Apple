import Foundation

/// Whole-cache eviction for ``AssetCacheService``, split out of the main
/// file purely to stay under this package's file-length limit.
extension AssetCacheService {
    /// Evicts every entry from both cache layers. Exposed for tests and for
    /// an explicit user-initiated "clear cache" action; never called
    /// automatically.
    ///
    /// Issues a global invalidation *before* awaiting either cache
    /// layer's removal, so every operation already in flight (a normal
    /// fetch's eventual publish, or a revalidation's eventual 404/304/200
    /// outcome) that issued its token before this call can no longer
    /// pass its own authority check once this returns — none of them can
    /// resurrect anything this call is in the middle of clearing. Also
    /// cancels every currently in-flight fetch/revalidation task itself
    /// (not merely invalidating their eventual authority check), so a
    /// caller that asked to clear the cache does not keep paying for
    /// network work whose result is now guaranteed to be discarded.
    ///
    /// Every already-registered waiter for a fetch/revalidation this call
    /// is about to tear down is resumed (with `CancellationError`)
    /// synchronously here, *before* its entry is removed from
    /// `inFlight`/`inFlightRevalidation` — this is required, not merely
    /// cosmetic: a plain `task.cancel()` never itself resumes a waiter's
    /// continuation; only that shared task's own completion watcher
    /// (``completeFetch(_:fetchID:result:)``/
    /// ``completeRevalidation(_:fetchID:result:)``) or a specific waiter's
    /// own cancellation handler (``cancelWaiter(_:fetchID:waiterID:)``/
    /// ``cancelRevalidationWaiter(_:fetchID:waiterID:)``) do that, and
    /// once this method has already removed an entry, that entry's own
    /// completion watcher finds nothing left to match (`fetch.id ==
    /// fetchID` fails) and silently returns without resuming anything.
    /// Without this, a caller still suspended in ``coalescedFetch``/
    /// ``coalescedRevalidation`` at the moment this method ran would hang
    /// forever instead of observing `CancellationError`.
    ///
    /// **Throws only when the disk-durable cross-instance/cross-process
    /// authority fence itself failed to advance** —
    /// ``AssetError/clearFenceNotDurable(_:)`` specifically (see that
    /// case's own doc comment). In that case this call's own in-process
    /// state (the global-generation bump above, every in-flight
    /// cancellation, and the in-process memory-cache clear) has *already*
    /// taken effect by the time this throws — undoing any of that would
    /// not restore any actual authority a sibling instance/process could
    /// rely on, and this process's own future reads must stay just as
    /// distrustful of stale content as if the fence had truly advanced.
    /// What this throw specifically prevents is this call's caller
    /// mistaking a call that did *not* durably fence out a sibling
    /// instance/process for one that did — this must never be folded
    /// into ``lastDiskPersistenceFailure`` and silently swallowed the way
    /// an ordinary, merely-partial physical-deletion failure already is
    /// (that failure mode remains non-fatal below, exactly as before:
    /// once the fence itself is durably advanced, best-effort physical
    /// cleanup — and this process's own tombstone bookkeeping for
    /// whatever it could not immediately delete — is sufficient, since
    /// every disk hit for any key must independently pass a fresh online
    /// conditional revalidation regardless; see ``AssetDiskCache``'s own
    /// doc comment).
    func evictAll() async throws {
        issueGlobalInvalidation()
        for (_, fetch) in inFlight {
            for (_, continuation) in fetch.waiters {
                continuation.resume(returning: .failure(CancellationError()))
            }
            fetch.task.cancel()
        }
        for (_, fetch) in inFlightRevalidation {
            for (_, continuation) in fetch.waiters {
                continuation.resume(returning: .failure(CancellationError()))
            }
            fetch.task.cancel()
        }
        inFlight.removeAll()
        removeAllInFlightRevalidation()
        await memoryCache.removeAll()
        do {
            try await diskCache.removeAll()
            tombstonedKeys.removeAll()
            lastDiskPersistenceFailure = nil
        } catch let fenceError as AssetError where isFenceFailure(fenceError) {
            // The durable fence itself (the clear epoch, or the root-
            // authority transaction that guards it) never advanced: this
            // is categorically worse than a partial physical-deletion
            // failure (see this method's own doc comment) and must
            // propagate to this call's caller rather than being folded
            // into ``lastDiskPersistenceFailure`` as a soft, swallowed
            // failure. Recorded here too, purely for diagnostics/
            // instrumentation parity with the best-effort path below —
            // never treated as cleared.
            lastDiskPersistenceFailure = fenceError
            throw fenceError
        } catch {
            // `removeAll()` failed (partially or entirely): some entries
            // may still be physically present on disk. Snapshot *after*
            // this failed attempt, not before it — a pre-attempt snapshot
            // (via a separate, independently racy listing call) can never
            // be proven consistent with what `removeAll()` itself actually
            // saw or removed, and silently degrading that separate
            // snapshot to "no keys" on its own listing failure would let
            // an undeletable entry go completely untombstoned. Listing
            // the directory now instead reflects exactly what survived
            // this exact attempt (correctly excluding whatever
            // `removeAll()` did manage to remove before failing).
            //
            // `entryKeyHashes()` deliberately returns every raw filename
            // prefix it finds, including one from a corrupt/tampered/
            // attacker-controlled entry that would never actually decode
            // as a real key hash. Filter to only the 64-lowercase-hex
            // shape a genuine key hash always has (the same shape
            // ``AssetDiskCache/isValidContentHash(_:)`` already enforces
            // for content hashes) before ever constructing an
            // ``AssetCacheKey`` from it or growing `tombstonedKeys` with
            // it — an unfiltered, arbitrarily-many, arbitrarily-long
            // directory entry name must never be able to inflate this
            // in-memory set without bound.
            //
            // `tombstonedKeys` is purely an in-process, best-effort
            // optimization (skip a disk read this process already
            // expects to be pointless) — never a correctness requirement:
            // even a key this snapshot fails to capture (because
            // `entryKeyHashes()` itself could not enumerate the
            // directory) can never be served stale, because *every* disk
            // hit for *any* key must independently pass a fresh online
            // conditional revalidation before ``AssetCacheService/asset(for:)``/
            // ``AssetCacheService/revalidate(for:)`` will ever trust or
            // return it — see ``AssetDiskCache``'s own doc comment. A
            // whole-cache "disable all disk reads" fallback is therefore
            // no longer needed here even when enumeration itself fails.
            let survivingKeys = await survivingValidKeyHashes()
            tombstonedKeys.formUnion(survivingKeys)
            lastDiskPersistenceFailure = error as? AssetError
                ?? .cachePersistenceFailed(String(describing: error))
        }
    }

    /// Every currently-listable directory entry's key-hash prefix,
    /// filtered to the 64-lowercase-hex shape a genuine key hash always
    /// has (see ``AssetDiskCache/isValidContentHash(_:)``) and converted
    /// to an ``AssetCacheKey``. Returns an empty array (never `nil`, and
    /// never throws) on any enumeration failure -- see this method's only
    /// call site's doc comment on why an incomplete snapshot is an
    /// acceptable, purely best-effort degradation rather than a
    /// correctness requirement.
    private func survivingValidKeyHashes() async -> [AssetCacheKey] {
        guard let rawNames = try? await diskCache.entryKeyHashes() else { return [] }
        return rawNames
            .filter { AssetDiskCache.isValidContentHash($0) }
            .map { AssetCacheKey(digestHex: $0) }
    }

    /// `true` only for ``AssetError/clearFenceNotDurable(_:)`` — the one
    /// ``AssetDiskCache/removeAll()`` failure mode that must propagate
    /// out of ``evictAll()`` rather than being folded into the same
    /// best-effort/tombstoned handling as every other error it can throw
    /// (an ordinary partial physical-deletion or removal-pass `fsync`
    /// failure, both still surfaced as ``AssetError/cachePersistenceFailed(_:)``).
    /// Factored out purely so the `catch` clause above stays legible.
    private func isFenceFailure(_ error: AssetError) -> Bool {
        if case .clearFenceNotDurable = error {
            return true
        }
        return false
    }

    /// Removes `cacheKey` from both cache layers, tombstoning it if the
    /// disk deletion could not be confirmed to fully succeed (see
    /// ``tombstonedKeys``). Centralizes every disk-invalidating call site
    /// (a definitive 404, a failed re-validation quarantine) so none of
    /// them can accidentally swallow a deletion failure the way a bare
    /// `try?`/best-effort `remove` used to.
    ///
    /// `token` is optional: a re-validation quarantine
    /// (``revalidateDiskHit(_:key:cacheKey:candidates:token:)``'s own
    /// `catch`) still passes its caller's token so this stays gated like
    /// every other mutation, but this is also called with no token at all
    /// from contexts that are not part of any issuance race (there is no
    /// prior in-flight operation whose authority could be superseded).
    /// Returns ``MutationOutcome/stale`` under the same conditions
    /// ``publish(_:asset:token:)`` does (only ever possible when `token`
    /// is non-`nil`: a `nil` token has no authority to lose).
    @discardableResult
    func invalidate(_ cacheKey: AssetCacheKey, token: CacheToken? = nil) async -> MutationOutcome {
        if let token, await !isAuthoritative(token, for: cacheKey) {
            return .stale
        }
        // Recorded *before* the memory removal itself (the actual
        // suspension below), so a concurrent reader that snapshotted
        // ``snapshotAuthority(for:)`` before this call started will
        // correctly observe a change even if it resumes while this call
        // is still suspended partway through — see
        // ``AssetCacheService/CacheToken/clearGeneration``'s doc comment
        // for why this is deliberately a distinct counter from
        // ``keyLatestToken``, now folded into every issued token and
        // checked by every ``isAuthoritative(_:for:)``/
        // ``unchanged(since:for:)`` call uniformly.
        //
        // `newClearGeneration` is captured once, right here, so every
        // subsequent re-check in *this* call compares against the value
        // *this exact call* just established -- never a live re-read of
        // ``keyClearGeneration`` -- because a live re-read would always
        // find `token.clearGeneration` (captured at issuance, before this
        // bump) stale against the bump this very call just performed,
        // wrongly rejecting a genuinely still-authoritative operation as
        // superseded by its own side effect. A *further* bump by some
        // other concurrent invalidation/`evictAll()` while this call is
        // itself suspended below is still caught: it would advance
        // `keyClearGeneration` a second time past `newClearGeneration`,
        // which the checks below compare against exactly.
        noteAuthorityKeyTouched(cacheKey)
        let newClearGeneration = (keyClearGeneration[cacheKey] ?? 0) + 1
        keyClearGeneration[cacheKey] = newClearGeneration
        /// `token`'s own ``CacheToken/durableClearEpoch`` (stamped at
        /// issuance time -- see ``AssetCacheService/beginIssuance(for:)``)
        /// is re-checked against a freshly re-read
        /// ``currentDurableClearEpoch()`` at every one of this method's
        /// own re-checks below, exactly like ``isAuthoritative(_:for:)``
        /// itself, so a cross-instance/cross-process clear that lands
        /// while this call is suspended is caught here too, not only by
        /// the up-front gate above.
        func stillAuthoritative() async -> Bool {
            guard let token else { return true }
            guard
                token.generation == globalGeneration,
                keyLatestToken[cacheKey] == token,
                keyClearGeneration[cacheKey] == newClearGeneration
            else {
                return false
            }
            guard
                let tokenEpoch = token.durableClearEpoch,
                let currentEpoch = await currentDurableClearEpoch()
            else {
                return false
            }
            return tokenEpoch == currentEpoch
        }
        await memoryCache.remove(cacheKey, token: token)
        guard await stillAuthoritative() else {
            return .stale
        }
        var diskOutcomeIsStale = false
        do {
            let diskOutcome = try await diskCache.remove(cacheKey, token: token)
            diskOutcomeIsStale = diskOutcome == .stale
            lastDiskPersistenceFailure = nil
        } catch let error as AssetError {
            tombstonedKeys.insert(cacheKey)
            lastDiskPersistenceFailure = error
        } catch {
            tombstonedKeys.insert(cacheKey)
            lastDiskPersistenceFailure = .cachePersistenceFailed(String(describing: error))
        }
        guard !diskOutcomeIsStale else {
            // The disk-durable, cross-instance/cross-process CAS itself
            // rejected this removal as stale: a more-recently-issued
            // sibling instance/process sharing this same directory has
            // already published a newer write for this exact key since
            // `token` was issued. This call's own memory removal above
            // must not be allowed to stand as if this invalidation were
            // still authoritative — otherwise a caller could believe this
            // key was cleanly invalidated while a sibling's genuinely
            // newer content survives untouched on disk, with nothing to
            // repopulate this instance's own memory cache for it. There
            // is nothing further to retract here (the removal, being
            // rejected, never took effect), so this simply reports
            // `.stale` exactly like every other authority re-check.
            return .stale
        }
        guard await stillAuthoritative() else {
            return .stale
        }
        return .applied
    }
}
