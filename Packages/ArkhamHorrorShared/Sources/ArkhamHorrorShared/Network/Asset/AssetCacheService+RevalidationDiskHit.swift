import Foundation

/// Re-validation of an already-trusted on-disk hit against the *current*
/// validation contract, before ever returning it as a resolved asset. Split
/// out of `AssetCacheService+Revalidation.swift` purely to keep each file
/// within this package's file/type-length conventions; still part of the
/// single `AssetCacheService` actor's isolated state.
extension AssetCacheService {
    /// Re-validates an on-disk cache hit against the *current* validation
    /// contract before ever trusting it as an already-resolved asset.
    ///
    /// ``AssetDiskCache/get(_:)`` already re-verifies the payload's byte
    /// count and SHA-256 hash against its own metadata (so the bytes are
    /// exactly what was written), but that alone does not prove the
    /// payload is still a genuinely valid, fully decodable image under
    /// *this process's* current limits: limits can tighten between
    /// launches, and a previously-published entry could in principle
    /// predate a validation fix. This re-runs the full
    /// format/magic-byte/dimension validation, cross-checks the freshly
    /// parsed dimensions against what metadata claims, and performs a full
    /// platform decode — never trusting metadata's `width`/`height` alone
    /// to stand in for a real decode.
    ///
    /// Returns `nil` (having already quarantined the disk entry) on any
    /// genuine mismatch or validation/decode failure. A `CancellationError`
    /// is rethrown instead of quarantining: it means the caller stopped
    /// caring, not that the entry is invalid.
    ///
    /// The persisted `resolvedURLString` is untrusted: a disk hit is only
    /// accepted when it exactly matches one of `key`'s own current
    /// candidates (never whatever URL happens to be recorded), which also
    /// recovers the exact ``AssetFormat`` that candidate resolved to.
    ///
    /// **Deliberately takes no `token` parameter and reserves no durable
    /// per-key disk authority on its own successful (common) path.** A
    /// prior revision required every caller to eagerly reserve a fresh
    /// disk ticket (via `beginRevalidationIssuance`) before this method
    /// ever ran, purely for its own rare quarantine-on-failure branch —
    /// durably bumping the shared per-key issuance counter even on the
    /// common success path that never needed one, which could wrongly
    /// reject an already in-flight, legitimately
    /// *joined* operation's earlier ticket as stale once it tried to
    /// publish. Reserving only lazily, from inside
    /// ``quarantineDiskHit(_:cacheKey:)`` below, and only on the rare
    /// failure branch, means the common success path reserves nothing —
    /// and every caller can defer its *own* authority reservation
    /// entirely to ``coalescedRevalidation``'s own join-or-create
    /// decision (`preIssuedAuthority: nil`), so a joiner truly
    /// reserves/issues nothing.
    func revalidateDiskHit(
        _ cached: CachedAsset,
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate]
    ) async throws -> CachedAsset? {
        guard let candidate = candidates.first(where: {
            $0.url(base: key.source).absoluteString == cached.metadata.resolvedURLString
        }) else {
            await quarantineDiskHit(cached, cacheKey: cacheKey)
            return nil
        }
        do {
            let validated = try AssetImageValidator.validate(
                data: cached.payload,
                declaredContentType: cached.metadata.contentType,
                expectedFormat: candidate.format,
                limits: limits
            )
            guard
                validated.width == cached.metadata.width,
                validated.height == cached.metadata.height
            else {
                throw AssetError.malformedImageData
            }
            let decoded = try await decodeImageOffActor(cached.payload)
            guard decoded.width == validated.width, decoded.height == validated.height else {
                throw AssetError.malformedImageData
            }
            return cached
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await quarantineDiskHit(cached, cacheKey: cacheKey)
            return nil
        }
    }

    /// Reserves a fresh disk-authority token, lazily and only now that a
    /// quarantine is actually needed, and invalidates `cacheKey`'s disk
    /// entry with it. `cached`'s historical stamp (`durableClearEpoch`/
    /// `writeGeneration`/`payloadSHA256Hex`) is validated atomically
    /// alongside this reservation via `beginRevalidationIssuance`.
    /// If that stamp is missing or no longer matches current durable
    /// reality (already superseded by a sibling clear/publish/retraction
    /// or quarantine), there is nothing left to safely retract, so this
    /// simply returns without touching disk. A subsequent
    /// ``AssetCacheService/invalidate(_:token:)`` failure (the durable
    /// disposition transaction itself could not be committed) is
    /// deliberately swallowed here (`try?`): this quarantine path is
    /// itself already best-effort local cleanup for an entry this call's
    /// own caller has independently decided not to trust any further —
    /// unlike ``AssetCacheService+RevalidationCoalescing.swift``'s own
    /// definitive-404 call site, nothing here depends on this
    /// invalidation having durably landed for its own outward-facing
    /// correctness.
    private func quarantineDiskHit(_ cached: CachedAsset, cacheKey: AssetCacheKey) async {
        guard
            let historicalEpoch = cached.durableClearEpoch,
            let historicalGeneration = cached.writeGeneration,
            let authority = await beginRevalidationIssuance(
                for: cacheKey,
                historicalClearEpoch: historicalEpoch,
                historicalWriteGeneration: historicalGeneration,
                historicalContentHash: cached.metadata.payloadSHA256Hex
            )
        else {
            return
        }
        var token = issueToken(for: cacheKey)
        token.durableClearEpoch = authority.clearEpoch
        token.diskWriteGeneration = authority.diskWriteGeneration
        _ = try? await invalidate(cacheKey, token: token)
    }
}
