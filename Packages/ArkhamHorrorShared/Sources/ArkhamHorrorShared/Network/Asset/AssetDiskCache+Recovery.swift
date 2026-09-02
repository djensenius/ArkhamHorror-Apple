import Foundation

/// Startup orphan/generation recovery and disk-quota eviction for
/// ``AssetDiskCache``, split out of `AssetDiskCache.swift` (which retains
/// `get`/`set`/`touch`/`remove` and the atomic-write primitives) purely to
/// stay under SwiftLint's `file_length`. Every filesystem operation here
/// goes through ``AssetDiskCache/directoryAccess``, the same verified,
/// descriptor-relative ``SecureCacheDirectory`` used by the rest of this
/// cache — never a `FileManager` path-string API, so recovery can never be
/// tricked into following a symlink planted at any entry name (including
/// the root directory being externally replaced between two recovery
/// passes: the held descriptor from `init` is reused unconditionally).
extension AssetDiskCache {
    /// Removes every payload file for `keyHash` except the one named for
    /// `keepingContentHash` (or every payload file for `keyHash` if `nil`),
    /// covering both a normal replacement's now-superseded prior generation
    /// and any extra stale generation(s) a previous crash left behind
    /// between a payload write and its metadata pointer commit. Best
    /// effort: an individual removal failure here does not change whether
    /// `keyHash` is servable again (`get` cannot serve any payload without
    /// a metadata pointer already having been confirmed removed by the
    /// caller) — it only risks a temporarily leaked file that a later
    /// recovery pass reclaims.
    func cleanupSupersededPayloads(
        forKeyHash keyHash: String,
        keeping keepingContentHash: String?
    ) {
        guard let names = try? directoryAccess.listNames() else { return }
        let prefix = "\(keyHash)."
        let keepName = keepingContentHash.map { payloadFilename(keyHash: keyHash, contentHash: $0) }
        for name in names {
            guard name.hasPrefix(prefix), name.hasSuffix(".bin"), name != keepName else { continue }
            _ = try? directoryAccess.remove(name: name)
        }
    }

    /// Runs once per cache instance lifetime in ordinary steady-state
    /// operation (covering the common "cache created once at app launch"
    /// case, which is what makes this a real restart-recovery pass rather
    /// than a per-call cost, and what keeps a read-only caller like
    /// ``AssetDiskCache/get(_:)``'s clean-miss path O(1)). Removes any
    /// leftover `.tmp` file from an interrupted write, any metadata
    /// sidecar that fails to decode or validate, and any payload file not
    /// named for the exact content hash a currently valid metadata
    /// sidecar references. Also reconciles the durable, cross-instance/
    /// cross-process access-sequence counter
    /// (``SecureCacheDirectory/floorAccessSequence(atLeast:)``) to be at
    /// least the highest ``AssetCacheMetadata/accessSequence`` found among
    /// every currently valid persisted entry, so every value allocated
    /// afterward is guaranteed greater than every value already on disk
    /// at the moment of this scan, required for LRU order to survive a
    /// restart correctly.
    ///
    /// - Parameter forceRetry: When `true`, re-runs the full scan even if
    ///   ``didRecoverOrphans`` is already set from an earlier call whose
    ///   own listing succeeded but left some removal unresolved —
    ///   ``AssetDiskCache/ensureRootAuthorityInitializedLocked()`` always
    ///   passes `true` here (see that method's own doc comment for why);
    ///   every other call site, including ``AssetDiskCache/get(_:)``'s
    ///   read path, uses the default `false` and keeps this one-shot.
    ///   Every step a retry repeats is itself idempotent (a floor bump to
    ///   an already-reached value, or sweeping an already-removed name,
    ///   is a safe no-op).
    func recoverOrphansIfNeeded(forceRetry: Bool = false) {
        guard !didRecoverOrphans || forceRetry else { return }
        // Only mark recovery as done once the directory listing actually
        // succeeds. If listing fails (e.g. a transient I/O error),
        // `didRecoverOrphans` must stay `false` so the very next call
        // retries orphan/tmp cleanup instead of it being silently,
        // permanently disabled for the lifetime of this cache instance.
        //
        // Crucially, a failed listing here must *also* durably disable
        // disk writes before returning. This is the recovery pass that
        // runs before ``AssetDiskCache/requireDiskWritesEnabledLocked()``
        // is even consulted by `set` — if it silently no-ops on an
        // unenumerable directory instead, the very first `set` call ever
        // made against a directory whose listing happens to fail at that
        // exact instant would sail straight through
        // `requireDiskWritesEnabledLocked()` (which only re-verifies the
        // budget when the disabled marker is *already* set) and publish
        // a new payload despite physical on-disk usage being completely
        // unknown at that moment. Marking writes disabled here — the same
        // durable marker ``evictIfNeeded()`` uses — closes that window:
        // "uncertainty synchronously disables writes until fully
        // recovered," not merely "until the next successful `set`
        // happens to also fail before writing."
        guard let names = try? directoryAccess.listNames() else {
            markDiskWritesDisabledLocked()
            return
        }
        didRecoverOrphans = true
        _ = secureDirectory.reclaimOrphanedIssuanceOwnerMarkers(names)

        var referencedPayloadFilenames: Set<String> = []
        var highestAccessSequence: Int?
        for name in names where name.hasSuffix(".meta.json") {
            let keyHash = String(name.dropLast(".meta.json".count))
            guard
                let data = try? directoryAccess.read(
                    name: name,
                    maxBytes: SecureCacheDirectory.maxMetadataBytes
                ),
                let metadata = try? JSONDecoder.assetCache().decode(
                    AssetCacheMetadata.self,
                    from: data
                ),
                metadata.schemaVersion == AssetCacheMetadata.currentSchemaVersion,
                metadata.cacheKeyHex == keyHash,
                Self.isValidContentHash(metadata.payloadSHA256Hex)
            else {
                _ = try? directoryAccess.remove(name: name)
                continue
            }
            let referencedPayloadName = payloadFilename(
                keyHash: keyHash,
                contentHash: metadata.payloadSHA256Hex
            )
            // A metadata sidecar whose referenced payload file does not
            // actually exist on disk *as a verified regular file* is
            // itself an orphan (e.g. left behind by a crash between the
            // metadata commit and a previous, separately-crashed payload
            // write, or by external tampering — including a symlink or
            // other non-regular entry planted at that exact name) —
            // quarantine it too, rather than leaving it to be discovered
            // only the next time this exact key is read. Accepting a
            // non-regular entry here would also wrongly mark that name
            // "referenced" below, letting the `.bin` orphan sweep skip
            // removing it.
            guard
                (try? directoryAccess.attributes(name: referencedPayloadName))?.isRegularFile
                == true
            else {
                _ = try? directoryAccess.remove(name: name)
                continue
            }
            referencedPayloadFilenames.insert(referencedPayloadName)
            highestAccessSequence = max(
                highestAccessSequence ?? metadata.accessSequence.value,
                metadata.accessSequence.value
            )
        }
        _ = sweepOrphanFiles(names: names, referencedPayloadFilenames: referencedPayloadFilenames)
        reconcileAccessSequenceFloor(highestAccessSequence)
    }

    /// Attempts to remove every leftover `.tmp` file and every `.bin`
    /// payload not present in `referencedPayloadFilenames`, then returns
    /// the total on-disk bytes of any such file that could **not** actually
    /// be removed (a real removal failure — e.g. a permission error — not
    /// merely "did not exist"), so quota accounting can never silently
    /// treat a still-present, unreclaimed file as though its bytes had
    /// already been freed.
    ///
    /// Called from both ``recoverOrphansIfNeeded()`` (once per instance
    /// lifetime) and ``evictIfNeeded()`` (every ``set(_:payload:metadata:token:)``),
    /// so a transient removal failure is retried on every subsequent
    /// write rather than being permanently given up on the moment the
    /// one-time startup recovery pass happened to run — a persistently
    /// unremovable orphan (e.g. a temporarily read-only filesystem, or a
    /// concurrent external process holding the name open) is retried
    /// indefinitely, and its bytes remain counted against the quota for
    /// exactly as long as it remains stranded, never silently forgotten
    /// beyond that.
    ///
    /// Takes an already-listed `names` array rather than listing the
    /// directory itself, so a caller that already needed a listing for
    /// another purpose in the same operation (``evictIfNeeded()``, via
    /// ``entries(names:)``) never pays for — or can transiently fail on —
    /// a second, redundant directory listing.
    ///
    /// Returns `nil` — rather than silently treating it as zero stranded
    /// bytes — if any orphan-candidate name that could not be removed
    /// turns out to be a **non-regular** entry (a directory, FIFO, device
    /// node, or symlink planted at a `.tmp`/`.bin`-suffixed name, whether
    /// by external tampering or a very unusual failure mode): such an
    /// entry still occupies a real directory slot (and, for a directory,
    /// arbitrarily many additional physical bytes/inodes this cache has
    /// no way to safely enumerate without walking into it), so accounting
    /// must treat its size as *unknown*, not zero, exactly like a stat
    /// failure. Every other name in `names` is still attempted first, so
    /// one such entry never prevents every other genuine orphan in the
    /// same pass from being reclaimed.
    @discardableResult
    func sweepOrphanFiles(names: [String], referencedPayloadFilenames: Set<String>) -> Int? {
        var strandedBytes = 0
        var sawUncertain = false
        for name in names {
            let isOrphanCandidate = name.hasSuffix(".tmp")
                || (name.hasSuffix(".bin") && !referencedPayloadFilenames.contains(name))
            guard isOrphanCandidate else { continue }
            _ = try? directoryAccess.remove(name: name)
            // Re-check after attempting removal, rather than trusting
            // `remove(name:)`'s own return value alone: this is the one
            // place that must distinguish "successfully removed" and
            // "never existed" (both fine — nothing to strand) from "still
            // present because the removal attempt itself failed" (its
            // bytes are still physically occupying the cache directory
            // and must not vanish from quota accounting).
            guard let attributes = try? directoryAccess.attributes(name: name) else {
                // Confirmed gone.
                continue
            }
            guard attributes.isRegularFile else {
                sawUncertain = true
                continue
            }
            strandedBytes += attributes.size
        }
        return sawUncertain ? nil : strandedBytes
    }
}
