import Foundation

extension LocaleCatalogLoader {
    /// Every eager chunk the selected locale's own resolution chain needs — the locale itself
    /// and every fallback up to and including the default — so a key absent from a partial
    /// locale always has somewhere to resolve to without a second network round trip
    /// mid-render. Deferred packs are left for ``loadDeferredPacks(for:advertisement:profile:)``.
    static func eagerChunkLocations(
        manifest: LocaleCatalogManifest, locale: String
    ) throws -> [LocaleCatalogChunkLocation] {
        guard let locations = manifest.chunkLocations(chainFrom: locale) else {
            throw LocaleCatalogFailure.malformedManifest
        }
        return locations.filter { !$0.isDeferred }
    }

    /// Loads every deferred-pack chunk `snapshot`'s chain lists (the selected locale and each
    /// fallback) and returns a new snapshot that holds them, all or nothing.
    ///
    /// The cache entry the snapshot came from is tried first; each cached file is re-hashed
    /// against its descriptor. Otherwise each chunk goes through the same policed fetch as the
    /// eager load (status, origin, MIME, `nosniff`, size, SHA-256, identity), counted against
    /// the same total-bytes and chunk-count ceilings on top of the manifest and the chunks
    /// already held (``LocaleCatalogSnapshot/manifestBudgetBytes``), so eager plus deferred
    /// never exceeds ``LocaleCatalogLimits/maxCatalogBytes``. A
    /// failure yields no snapshot; the caller keeps `snapshot`, whose `cardNames.*` lookups
    /// miss and so keep the server-sent name.
    func loadDeferredPacks(
        for snapshot: LocaleCatalogSnapshot,
        advertisement: LocaleCatalogAdvertisement,
        profile: ServerProfile
    ) async -> Result<LocaleCatalogSnapshot, LocaleCatalogFailure> {
        let pending = snapshot.pendingDeferredChunks
        guard !pending.isEmpty else { return .success(snapshot) }
        guard let manifestURL = advertisement.resolvedManifestURL(for: profile),
              let origin = LocaleCatalogOrigin(url: manifestURL)
        else { return .failure(.unresolvableManifestURL) }
        // The chunk URLs are resolved from this advertisement and profile, so they must be the
        // ones the snapshot was verified against.
        guard manifestURL.absoluteString == snapshot.identity.endpoint,
              advertisement.catalogRevision == snapshot.identity.catalogRevision,
              advertisement.manifestSha256 == snapshot.identity.manifestSha256
        else { return .failure(.malformedManifest) }

        if let cached = await storage?.loadDeferred(snapshot: snapshot) {
            return .success(cached)
        }
        let held = snapshot.heldChunkLocations
        let fetched: FetchedChunks
        do {
            fetched = try await fetchChunks(
                pending,
                advertisement: advertisement,
                profile: profile,
                origin: origin,
                initialBytes: held.reduce(snapshot.manifestBudgetBytes) {
                    $0 + $1.descriptor.bytes
                },
                initialChunkCount: held.count
            )
        } catch let failure as LocaleCatalogFailure {
            return .failure(failure)
        } catch {
            return .failure(.transportFailure)
        }
        guard let augmented = snapshot.adding(chunks: fetched.chunks) else {
            return .failure(.malformedManifest)
        }
        await storage?.storeDeferred(snapshot: augmented, chunkBytes: fetched.bytes)
        return .success(augmented)
    }
}
