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

    /// Runs once per cache instance lifetime (covering the common "cache
    /// created once at app launch" case, which is what makes this a real
    /// restart-recovery pass rather than a per-call cost). Removes any
    /// leftover `.tmp` file from an interrupted write, any metadata sidecar
    /// that fails to decode or validate, and any payload file not named
    /// for the exact content hash a currently valid metadata sidecar
    /// references. Also reconciles the durable, cross-instance/cross-process
    /// access-sequence counter (``SecureCacheDirectory/floorAccessSequence(atLeast:)``)
    /// to be at least the highest ``AssetCacheMetadata/accessSequence``
    /// found among every currently valid persisted entry, so every value
    /// allocated afterward — by this instance, another concurrent
    /// instance, or a genuinely separate process — is guaranteed greater
    /// than every value already on disk at the moment of this scan,
    /// required for LRU order to survive a restart correctly.
    func recoverOrphansIfNeeded() {
        guard !didRecoverOrphans else { return }
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

    // MARK: - Eviction

    /// One valid entry's identity, decoded metadata, and its metadata
    /// sidecar's exact serialized byte count (the same `Data` this decodes
    /// `metadata` from), so accounting never relies on an estimate for
    /// bytes that are actually persisted to disk.
    ///
    /// `payloadBytes` is likewise the actual on-disk payload file size (via
    /// a symlink-safe `fstatat`, never `metadata.encodedByteCount`): metadata
    /// is untrusted input, and if the payload file were ever larger than
    /// metadata claims — corruption, a partial write, or external
    /// modification — trusting the claimed size would let eviction
    /// undercount real disk usage until that exact key was next read via
    /// `get(_:)` and quarantined there. See ``get(_:)`` for the same
    /// actual-file-size check applied on the read path.
    struct Entry {
        let hash: String
        let metadata: AssetCacheMetadata
        let metadataBytes: Int
        let payloadBytes: Int
    }

    /// The exact bytes an entry counts against the disk quota: the real
    /// on-disk payload file size plus the real serialized size of its
    /// metadata sidecar file — never a fixed estimate, and never a value
    /// merely claimed by (untrusted) metadata.
    static func accountedBytes(for entry: Entry) -> Int {
        entry.payloadBytes + entry.metadataBytes
    }

    /// Evicts the least-recently-used entries (by
    /// ``AssetCacheMetadata/accessSequence``, tie-broken deterministically
    /// by the entry's own key hash — never filesystem `atime`, and never a
    /// wall-clock `Date`) until total accounted bytes falls to or below
    /// ``AssetCacheLimits/lowWaterMarkDiskBytes``. Quota accounting only
    /// ever subtracts an entry's bytes once *both* its payload and its
    /// metadata sidecar have been successfully removed: a failed removal
    /// leaves that entry's bytes fully counted (so quota accounting can
    /// never under-report real disk usage), and this method does not
    /// throw or stop early on an individual removal failure — it keeps
    /// evicting other entries so one unremovable entry can never mask
    /// eviction of everything else.
    ///
    /// Also sweeps orphaned `.bin`/`.tmp` files (see
    /// ``sweepOrphanFiles(names:referencedPayloadFilenames:)``) and every
    /// other cache-owned file this directory can contain — durable
    /// per-key tombstones, the whole-cache disabled markers, and the
    /// cross-process lock file itself — on every call, not merely once at
    /// startup, and folds whatever bytes any of those account for into
    /// `total` before comparing against the water marks: every one of
    /// those files physically occupies disk space this cache is
    /// responsible for, regardless of whether any currently valid
    /// metadata sidecar references it, and omitting any of them would let
    /// real usage exceed the budget this method is supposed to enforce
    /// without that ever being visible to it. Lists the directory exactly
    /// once for every purpose here, so a transient listing failure has
    /// one, not several, chances to affect a single `set` call.
    ///
    /// This is also this cache's sole "prove the budget" recovery path:
    /// if the directory cannot be listed, if any stray file's size cannot
    /// be determined, or if accounted usage still exceeds
    /// ``AssetCacheLimits/highWaterMarkDiskBytes`` even after evicting
    /// every evictable entry, this durably marks disk *writes* disabled
    /// (see ``AssetDiskCache/requireDiskWritesEnabledLocked()``) rather
    /// than merely returning early — a persistently-unknown or
    /// persistently-over-budget disk state must stop new bytes from
    /// being accepted at all, not merely fail to reclaim old ones. A
    /// fully successful pass (enumerable, fully accounted, and within
    /// budget by the end) clears that marker again, so a transient
    /// failure never permanently disables writes once conditions
    /// improve.
    func evictIfNeeded() {
        guard let names = try? directoryAccess.listNames() else {
            markDiskWritesDisabledLocked()
            return
        }
        guard var accounted = accountedUsage(names: names) else {
            // Every individual "physical usage is not fully known" case
            // is documented on ``accountedUsage(names:)`` itself; all of
            // them must fail closed exactly the same way an unenumerable
            // directory listing does.
            markDiskWritesDisabledLocked()
            return
        }
        if accounted.total > limits.highWaterMarkDiskBytes {
            accounted.entries.sort {
                $0.metadata.accessSequence != $1.metadata.accessSequence
                    ? $0.metadata.accessSequence < $1.metadata.accessSequence
                    : $0.hash < $1.hash
            }
            for entry in accounted.entries {
                guard accounted.total > limits.lowWaterMarkDiskBytes else { break }
                let payloadName = payloadFilename(
                    keyHash: entry.hash,
                    contentHash: entry.metadata.payloadSHA256Hex
                )
                let metadataName = "\(entry.hash).meta.json"
                let payloadRemoved = (try? directoryAccess.remove(name: payloadName)) ?? false
                let metadataRemoved = (try? directoryAccess.remove(name: metadataName)) ?? false
                guard payloadRemoved, metadataRemoved else { continue }
                accounted.total -= Self.accountedBytes(for: entry)
            }
        }
        let fsyncSucceeded = (try? directoryAccess.fsyncRootDirectory()) != nil
        guard fsyncSucceeded, accounted.total <= limits.highWaterMarkDiskBytes
        else {
            // Either this pass's own cleanup `fsync` could not be
            // confirmed durable, or accounted usage is still over budget
            // even after evicting every entry this pass could remove
            // (e.g. persistent removal failures) — both mean the budget
            // is not currently provably under control, so writes must
            // stay (or become) disabled until a future pass proves
            // otherwise.
            markDiskWritesDisabledLocked()
            return
        }
        clearDiskWritesDisabledLocked()
    }

    /// Every currently-decodable entry plus the exact total accounted
    /// disk usage (entries + orphan/stray/quarantined-sidecar bytes),
    /// or `nil` if *any* component of that total could not be fully and
    /// safely determined -- factored out of ``evictIfNeeded()`` purely to
    /// keep that function's body within this package's
    /// `function_body_length` convention. Every `nil` case here means
    /// "physical usage is not fully known", which the caller must treat
    /// identically: fail closed exactly like an unenumerable directory
    /// listing, never silently under-counting or guessing.
    private func accountedUsage(
        names: [String]
    ) -> (entries: [Entry], total: Int)? {
        let (entriesResult, strandedSidecarBytes) = entries(names: names)
        let current = entriesResult
        // A quarantined invalid metadata sidecar's post-removal size
        // could not be confirmed.
        guard let strandedSidecarBytes else { return nil }
        let referencedPayloadFilenames = Set(current.map {
            payloadFilename(keyHash: $0.hash, contentHash: $0.metadata.payloadSHA256Hex)
        })
        // A surviving orphan candidate turned out to be a non-regular
        // entry whose real size cannot be safely determined.
        guard
            let strandedBytes = sweepOrphanFiles(
                names: names,
                referencedPayloadFilenames: referencedPayloadFilenames
            )
        else { return nil }
        // A stray cache-owned file's size could not be determined (e.g.
        // a tombstone/marker/lock file whose `fstatat` itself failed).
        guard let otherBytes = accountedStrayCacheFileBytes(names: names) else { return nil }
        let total = current.reduce(strandedBytes + otherBytes + strandedSidecarBytes) {
            $0 + Self.accountedBytes(for: $1)
        }
        return (current, total)
    }

    /// The accounted bytes of every cache-owned regular file in `names`
    /// that ``entries(names:)``/``sweepOrphanFiles(names:referencedPayloadFilenames:)``
    /// do not already account for — the whole-cache disabled-writes
    /// marker and the cross-process lock file — so ``evictIfNeeded()``'s
    /// budget accounting is never blind to any file this cache itself
    /// creates. Returns `nil` (rather than silently under-counting) if
    /// any such file's actual on-disk size could not be determined, or if
    /// any of them turns out to be a **non-regular** entry (a directory,
    /// FIFO, device node, or symlink occupying a name this cache
    /// otherwise expects to be a plain reserved marker/lock file): such
    /// an entry's true size (and, for a directory, its entire recursive
    /// contents) cannot be safely determined without walking into it, so
    /// it must never silently count as zero bytes.
    private func accountedStrayCacheFileBytes(names: [String]) -> Int? {
        var total = 0
        var sawUncertain = false
        for name in names {
            let isAlreadyAccountedElsewhere =
                name.hasSuffix(".meta.json") || name.hasSuffix(".tmp") || name.hasSuffix(".bin")
            guard !isAlreadyAccountedElsewhere else { continue }
            guard let attributes = try? directoryAccess.attributes(name: name) else {
                sawUncertain = true
                continue
            }
            guard attributes.isRegularFile else {
                sawUncertain = true
                continue
            }
            total += attributes.size
        }
        return sawUncertain ? nil : total
    }
}
