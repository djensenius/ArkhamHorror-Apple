import CryptoKit
import Foundation

/// Fetches, verifies, and assembles one complete catalog snapshot for one server profile.
///
/// The order of operations is the whole point and never varies:
/// 1. resolve the manifest URL against the *active profile's* own hosting context, never a
///    host this client chose;
/// 2. fetch those exact bytes over an isolated, unauthenticated transport;
/// 3. hash the exact bytes and require the digest the capabilities advertisement pinned
///    **before** the bytes are parsed, let alone trusted;
/// 4. parse through this module's lossless parser, which rejects duplicate object keys;
/// 5. validate against the closed v1 manifest schema *and* against the advertisement;
/// 6. fetch every chunk the selected locale's resolution chain needs, size- and
///    digest-checking each one and requiring its declared identity to match the descriptor;
/// 7. only then construct the immutable snapshot.
///
/// Any failure at any step yields a ``LocaleCatalogFailure`` and no snapshot at all. There is
/// deliberately no path that publishes a partially assembled revision.
struct LocaleCatalogLoader: Sendable {
    let transport: any LocaleCatalogTransporting
    let storage: (any LocaleCatalogStoring)?

    init(
        transport: any LocaleCatalogTransporting = URLSessionLocaleCatalogTransport(),
        storage: (any LocaleCatalogStoring)? = nil
    ) {
        self.transport = transport
        self.storage = storage
    }

    /// The production pipeline: the isolated unauthenticated transport plus the bounded
    /// on-disk cache, rooted in this app's own caches directory. The cache is simply omitted
    /// when no caches directory exists, because a catalog is always re-derivable from the
    /// server and a cache is an optimization, never an authority.
    static func production() -> LocaleCatalogLoader {
        let storage = FileLocaleCatalogStore.defaultRoot().map { FileLocaleCatalogStore(root: $0) }
        return LocaleCatalogLoader(
            transport: URLSessionLocaleCatalogTransport(), storage: storage
        )
    }

    // Loads the complete catalog for `advertisement` as served to `profile`, for the locale
    // selected from `preferredLanguages`.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func load(
        advertisement: LocaleCatalogAdvertisement,
        profile: ServerProfile,
        preferredLanguages: [String]
    ) async -> Result<LocaleCatalogSnapshot, LocaleCatalogFailure> {
        guard let manifestURL = advertisement.resolvedManifestURL(for: profile),
              let origin = LocaleCatalogOrigin(url: manifestURL)
        else { return .failure(.unresolvableManifestURL) }

        let initialManifest = await fetchManifest(
            url: manifestURL, origin: origin, advertisement: advertisement
        )
        let manifestBytes: Data
        let manifest: LocaleCatalogManifest
        switch initialManifest {
        case let .success(loaded):
            manifestBytes = loaded.bytes
            manifest = loaded.manifest
        case let .failure(failure):
            return .failure(failure)
        }

        let locale = LocaleCatalogSnapshot.resolveLocale(
            preferredLanguages: preferredLanguages,
            table: manifest.languageResolution,
            supportedLocales: Set(manifest.supportedLocales),
            defaultLocale: manifest.defaultLocale
        )
        guard manifest.record(for: locale) != nil else { return .failure(.localeUnavailable) }

        let identity = LocaleCatalogIdentity(
            endpoint: manifestURL,
            catalogRevision: manifest.catalogRevision,
            locale: locale,
            manifestSha256: advertisement.manifestSha256
        )
        if let cached = await storage?.load(identity: identity, manifest: manifest) {
            return .success(cached)
        }

        let fetched: FetchedChunks
        do {
            fetched = try await fetchChunks(
                manifest: manifest, locale: locale,
                advertisement: advertisement,
                profile: profile,
                origin: origin,
                initialBytes: manifestBytes.count
            )
        } catch LocaleCatalogFailure.unexpectedStatus(404) {
            // A content-addressed chunk can briefly lag the manifest during a rolling static
            // deployment. Re-check the exact advertisement-pinned manifest once, then retry
            // the complete bounded set exactly once. Any changed or no-longer-authorized
            // manifest fails in `fetchManifest`; no 404 is cached or retried recursively.
            guard !Task.isCancelled else { return .failure(.transportFailure) }
            switch await fetchManifest(
                url: manifestURL, origin: origin, advertisement: advertisement
            ) {
            case let .success(refreshed):
                do {
                    fetched = try await fetchChunks(
                        manifest: refreshed.manifest,
                        locale: locale,
                        advertisement: advertisement,
                        profile: profile,
                        origin: origin,
                        initialBytes: refreshed.bytes.count
                    )
                } catch let failure as LocaleCatalogFailure {
                    return .failure(failure)
                } catch {
                    return .failure(.transportFailure)
                }
            case let .failure(failure):
                return .failure(failure)
            }
        } catch let failure as LocaleCatalogFailure {
            return .failure(failure)
        } catch {
            return .failure(.transportFailure)
        }

        let snapshot = LocaleCatalogSnapshot(
            identity: identity, manifest: manifest, chunks: fetched.chunks
        )
        guard snapshot.isComplete else { return .failure(.malformedManifest) }
        await storage?.store(
            snapshot: snapshot, manifestBytes: manifestBytes, chunkBytes: fetched.bytes
        )
        return .success(snapshot)
    }

    /// Every chunk the selected locale's own resolution chain needs — the locale itself and
    /// every fallback up to and including the default — so a key absent from a partial locale
    /// always has somewhere to resolve to without a second network round trip mid-render.
    /// The verified chunk set plus the exact bytes each chunk arrived as, so the cache can
    /// persist and later re-hash the same bytes rather than a re-serialization of them.
    private struct FetchedChunks {
        var chunks: [LocaleCatalogChunkKey: LocaleCatalogChunk] = [:]
        var bytes: [String: Data] = [:]
    }

    private struct LoadedManifest {
        let bytes: Data
        let manifest: LocaleCatalogManifest
    }

    private func fetchManifest(
        url: URL,
        origin: LocaleCatalogOrigin,
        advertisement: LocaleCatalogAdvertisement
    ) async -> Result<LoadedManifest, LocaleCatalogFailure> {
        let bytes: Data
        do {
            bytes = try await fetchVerified(
                url,
                origin: origin,
                maxBytes: LocaleCatalogLimits.maxManifestBytes,
                expectedDigest: advertisement.manifestSha256,
                mismatch: .manifestDigestMismatch
            )
        } catch let failure as LocaleCatalogFailure {
            return .failure(failure)
        } catch {
            return .failure(.transportFailure)
        }
        guard let value = try? LosslessJSONParser.parse(
            bytes, maxByteCount: LocaleCatalogLimits.maxManifestBytes
        ) else {
            return .failure(.malformedJSON)
        }
        switch LocaleCatalogManifest.validate(value, against: advertisement) {
        case let .success(manifest):
            return .success(LoadedManifest(bytes: bytes, manifest: manifest))
        case let .failure(failure):
            return .failure(failure)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func fetchChunks(
        manifest: LocaleCatalogManifest,
        locale: String,
        advertisement: LocaleCatalogAdvertisement,
        profile: ServerProfile,
        origin: LocaleCatalogOrigin,
        initialBytes: Int
    ) async throws -> FetchedChunks {
        var fetched = FetchedChunks()
        var totalBytes = initialBytes
        for chainLocale in manifest.localeChain(from: locale) {
            guard let record = manifest.record(for: chainLocale) else {
                throw LocaleCatalogFailure.malformedManifest
            }
            for descriptor in record.chunks {
                try Task.checkCancellation()
                guard fetched.chunks.count < LocaleCatalogLimits.maxSnapshotChunks else {
                    throw LocaleCatalogFailure.tooLarge
                }
                totalBytes += descriptor.bytes
                guard totalBytes <= LocaleCatalogLimits.maxCatalogBytes else {
                    throw LocaleCatalogFailure.tooLarge
                }
                guard let url = advertisement.resolvedChunkURL(
                    path: descriptor.path, for: profile
                ) else { throw LocaleCatalogFailure.unresolvableManifestURL }
                let bytes = try await fetchVerified(
                    url,
                    origin: origin,
                    maxBytes: min(descriptor.bytes, LocaleCatalogLimits.maxChunkBytes),
                    expectedDigest: descriptor.sha256,
                    mismatch: .chunkDigestMismatch
                )
                // The manifest promised an exact size, so a shorter body that still hashes to
                // the promised digest is impossible; checking anyway keeps the two independent.
                guard bytes.count == descriptor.bytes else {
                    throw LocaleCatalogFailure.chunkDigestMismatch
                }
                guard let value = try? LosslessJSONParser.parse(
                    bytes, maxByteCount: LocaleCatalogLimits.maxChunkBytes
                ) else { throw LocaleCatalogFailure.malformedJSON }
                let validated = LocaleCatalogChunk.validate(
                    value,
                    expectedLocale: chainLocale,
                    expectedFallback: record.fallback,
                    expectedPack: descriptor.pack,
                    expectedKeys: descriptor.keys,
                    expectedUnsupportedKeys: descriptor.unsupportedKeys
                )
                switch validated {
                case let .success(chunk):
                    let key = LocaleCatalogChunkKey(locale: chainLocale, pack: descriptor.pack)
                    fetched.chunks[key] = chunk
                    fetched.bytes[descriptor.sha256] = bytes
                case let .failure(failure):
                    throw failure
                }
            }
        }
        return fetched
    }

    /// One fetch, fully policed: 200 only, JSON MIME with `nosniff`, same named origin, exact
    /// bounded read, and the promised SHA-256 over the exact bytes received.
    private func fetchVerified(
        _ url: URL,
        origin: LocaleCatalogOrigin,
        maxBytes: Int,
        expectedDigest: String,
        mismatch: LocaleCatalogFailure
    ) async throws -> Data {
        let response = try await transport.fetch(url, maxBytes: maxBytes)
        guard response.statusCode == 200 else {
            throw LocaleCatalogFailure.unexpectedStatus(response.statusCode)
        }
        // A response produced by a URL on any other origin means a redirect was followed
        // despite the delegate refusing them; it is rejected rather than trusted.
        if let responseURL = response.url, !origin.contains(responseURL) {
            throw LocaleCatalogFailure.redirected
        }
        guard Self.isAcceptableJSONResponse(response) else {
            throw LocaleCatalogFailure.unacceptableContentType
        }
        guard response.data.count <= maxBytes else { throw LocaleCatalogFailure.tooLarge }
        guard Self.sha256Hex(response.data) == expectedDigest else { throw mismatch }
        return response.data
    }

    /// The catalog routes are served `default_type application/json` with
    /// `X-Content-Type-Options: nosniff`. Both are required here: without the MIME check a
    /// misrouted request could be answered with the SPA shell, and without `nosniff` the
    /// server has not asserted that its own type declaration is authoritative.
    static func isAcceptableJSONResponse(_ response: LocaleCatalogResponse) -> Bool {
        guard let contentType = response.contentType else { return false }
        let mediaType = contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard LocaleCatalogGrammar.isASCII(mediaType) else { return false }
        let normalized = mediaType.lowercased()
        guard normalized == "application/json" || normalized.hasSuffix("+json") else {
            return false
        }
        guard let options = response.contentTypeOptions,
              LocaleCatalogGrammar.isASCII(options),
              options.lowercased().split(separator: ",").contains(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "nosniff"
              })
        else { return false }
        return true
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
