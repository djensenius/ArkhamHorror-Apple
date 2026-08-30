import Foundation

/// Listing and validating every currently-valid ``AssetDiskCache/Entry``
/// from a cache directory's `.meta.json` sidecars — including the
/// physical-quota accounting for any sidecar that turns out to be
/// invalid/undecodable and cannot be cleanly removed. Split out of
/// `AssetDiskCache+Recovery.swift` purely to keep that file within this
/// package's `file_length` convention; still part of the same
/// `AssetDiskCache` actor's isolated recovery/accounting subsystem.
extension AssetDiskCache {
    func entries() -> [Entry] {
        guard let names = try? directoryAccess.listNames() else { return [] }
        return entries(names: names).entries
    }

    /// Best-effort quarantines an invalid/undecodable/corrupt metadata
    /// sidecar named `name` (for the key hash `hash`) and its own
    /// now-orphaned payload generations, then reports how many bytes, if
    /// any, are still physically occupying disk immediately afterward —
    /// mirroring ``sweepOrphanFiles(names:referencedPayloadFilenames:)``'s
    /// own "re-check after attempting removal, never trust `remove(name:)`'s
    /// return value alone" pattern, for exactly the same reason: a sidecar
    /// whose removal attempt itself fails (a permission error, a
    /// momentarily read-only filesystem) is still physically present and
    /// must not silently vanish from quota accounting merely because it
    /// is invalid — it occupies exactly the same real disk bytes an
    /// unquarantinable orphan `.bin`/`.tmp` file would.
    ///
    /// Returns `nil` — rather than `0` — if this sidecar's own physical
    /// size cannot even be determined after the removal attempt (the
    /// `fstatat` itself failed for a reason other than the file being
    /// gone): real usage is not merely "some extra bytes", it is
    /// *unknown*, which ``evictIfNeeded()`` must treat identically to an
    /// unenumerable directory listing or an unreadable stray file — fail
    /// closed rather than silently under-counting. Deliberately does
    /// *not* use `try?` for this final check: `try?` on a `throws -> T?`
    /// function flattens the nested optional (per SE-0230), so it cannot
    /// by itself distinguish "the file is confirmed gone" (`nil`,
    /// genuinely zero stranded bytes — removal already succeeded, or the
    /// file never existed) from "the attributes check itself failed"
    /// (thrown error, size truly unknown) — exactly the two outcomes this
    /// method must tell apart.
    private func quarantineInvalidSidecar(name: String, forKeyHash hash: String) -> Int? {
        _ = try? directoryAccess.remove(name: name)
        cleanupSupersededPayloads(forKeyHash: hash, keeping: nil)
        do {
            guard let attributes = try directoryAccess.attributes(name: name) else {
                // Confirmed gone -- either this call's own removal above
                // succeeded, or the file never existed in the first
                // place. Either way, zero bytes are stranded.
                return 0
            }
            guard attributes.isRegularFile else { return 0 }
            return attributes.size
        } catch {
            return nil
        }
    }

    /// Same as ``entries()``, but reuses an already-listed `names` array
    /// instead of listing the directory itself — see
    /// ``sweepOrphanFiles(names:referencedPayloadFilenames:)`` for why
    /// ``evictIfNeeded()`` needs this to avoid a second, redundant (and
    /// separately fallible) directory listing per write.
    ///
    /// `strandedSidecarBytes` folds in every invalid metadata sidecar this
    /// pass attempted (and failed) to quarantine — see
    /// ``quarantineInvalidSidecar(name:forKeyHash:)`` — so those bytes are
    /// never silently excluded from budget accounting merely because they
    /// belong to a `.meta.json`-suffixed file, which
    /// ``accountedStrayCacheFileBytes(names:)`` otherwise always assumes
    /// is fully accounted for by this method's own `entries` result.
    /// `nil` propagates the same "physical usage is not fully known"
    /// fail-closed signal ``accountedStrayCacheFileBytes(names:)`` itself
    /// already uses — but only once every other name has still been
    /// processed: one sidecar whose post-quarantine size cannot be
    /// confirmed must not itself prevent every other invalid sidecar in
    /// this same pass from at least being attempted, even though the
    /// pass as a whole will still end up failing closed overall.
    func entries(names: [String]) -> (entries: [Entry], strandedSidecarBytes: Int?) {
        var result: [Entry] = []
        var strandedSidecarBytes = 0
        var sawUncertainStrandedSidecar = false
        for name in names where name.hasSuffix(".meta.json") {
            let hash = String(name.dropLast(".meta.json".count))
            guard let entry = decodeValidEntry(
                name: name,
                hash: hash,
                strandedSidecarBytes: &strandedSidecarBytes,
                sawUncertainStrandedSidecar: &sawUncertainStrandedSidecar
            ) else {
                continue
            }
            result.append(entry)
        }
        return (result, sawUncertainStrandedSidecar ? nil : strandedSidecarBytes)
    }

    /// Decodes and validates a single `.meta.json` sidecar named `name`
    /// (for key hash `hash`) into an ``Entry``, quarantining it (folding
    /// any still-physically-present bytes into `strandedSidecarBytes`, or
    /// setting `sawUncertainStrandedSidecar` if even that cannot be
    /// confirmed) on any decode/schema/cross-check failure. Split out of
    /// ``entries(names:)`` purely to keep that function's own body length
    /// within this package's convention; behavior is unchanged from its
    /// three previously-inlined, identically-shaped quarantine branches.
    private func decodeValidEntry(
        name: String,
        hash: String,
        strandedSidecarBytes: inout Int,
        sawUncertainStrandedSidecar: inout Bool
    ) -> Entry? {
        func quarantine() {
            if let stranded = quarantineInvalidSidecar(name: name, forKeyHash: hash) {
                strandedSidecarBytes += stranded
            } else {
                sawUncertainStrandedSidecar = true
            }
        }
        // An unreadable or undecodable sidecar can never be corrected by
        // itself; quarantining it here (rather than merely skipping it)
        // prevents it from silently occupying disk space forever,
        // uncounted against `diskBudgetBytes` and unevictable, until its
        // exact key happens to be looked up again via `get(_:)`.
        guard
            let data = try? directoryAccess.read(
                name: name,
                maxBytes: SecureCacheDirectory.maxMetadataBytes
            ),
            let metadata = try? JSONDecoder.assetCache().decode(
                AssetCacheMetadata.self,
                from: data
            )
        else {
            quarantine()
            return nil
        }
        guard metadata.schemaVersion == AssetCacheMetadata.currentSchemaVersion,
              metadata.cacheKeyHex == hash,
              Self.isValidContentHash(metadata.payloadSHA256Hex)
        else {
            quarantine()
            return nil
        }
        let payloadName = payloadFilename(keyHash: hash, contentHash: metadata.payloadSHA256Hex)
        guard
            let attributes = try? directoryAccess.attributes(name: payloadName),
            attributes.isRegularFile,
            attributes.size <= limits.maxEncodedBytes
        else {
            quarantine()
            return nil
        }
        return Entry(
            hash: hash,
            metadata: metadata,
            metadataBytes: data.count,
            payloadBytes: attributes.size
        )
    }
}
