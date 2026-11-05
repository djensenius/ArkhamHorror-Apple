@testable import ArkhamHorrorShared
import Foundation

/// The governed 0.1.63 catalog in `Fixtures/LocaleCatalog/Contract` (en, de and the card-only
/// pl each carry a `cardNames` pack), served byte-for-byte by a fixture transport.
struct VendoredLocaleCatalog {
    let profile: ServerProfile
    let advertisement: LocaleCatalogAdvertisement
    let manifest: LocaleCatalogManifest
    let manifestURL: URL
    let manifestBytes: Data
    let chunkURLs: [LocaleCatalogChunkKey: URL]
    let chunkBytes: [LocaleCatalogChunkKey: Data]

    static func make() throws -> VendoredLocaleCatalog {
        let capabilities = try ContractJSON.decode(
            ServerCapabilities.self, from: fixture("capabilities-locale-catalog")
        )
        guard let advertisement = capabilities.localeCatalog else { throw TestFailure() }
        let profile = try ServerProfile.custom(
            displayName: "Vendored locale catalog",
            rawURL: "https://catalog.example.test/profile-prefix"
        )
        let manifestBytes = try fixture("locale-catalog-manifest")
        let manifest = try LocaleCatalogManifest.validate(
            LosslessJSONParser.parse(manifestBytes), against: advertisement
        ).get()
        guard let manifestURL = advertisement.resolvedManifestURL(for: profile) else {
            throw TestFailure()
        }
        var chunkURLs: [LocaleCatalogChunkKey: URL] = [:]
        var chunkBytes: [LocaleCatalogChunkKey: Data] = [:]
        for record in manifest.locales {
            for descriptor in record.chunks {
                let key = LocaleCatalogChunkKey(locale: record.locale, pack: descriptor.pack)
                guard let url = advertisement.resolvedChunkURL(
                    path: descriptor.path, for: profile
                ) else { throw TestFailure() }
                chunkURLs[key] = url
                chunkBytes[key] = try fixture("locale-catalog-chunk-\(descriptor.sha256)")
            }
        }
        return VendoredLocaleCatalog(
            profile: profile,
            advertisement: advertisement,
            manifest: manifest,
            manifestURL: manifestURL,
            manifestBytes: manifestBytes,
            chunkURLs: chunkURLs,
            chunkBytes: chunkBytes
        )
    }

    private static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json",
            subdirectory: "Fixtures/LocaleCatalog/Contract"
        ) else { throw TestFailure() }
        return try Data(contentsOf: url)
    }

    func response(data: Data, url: URL) -> LocaleCatalogResponse {
        LocaleCatalogResponse(
            statusCode: 200,
            contentType: "application/json; charset=utf-8",
            contentTypeOptions: "nosniff",
            url: url,
            data: data
        )
    }

    func url(_ locale: String, _ pack: String) throws -> URL {
        guard let url = chunkURLs[LocaleCatalogChunkKey(locale: locale, pack: pack)] else {
            throw TestFailure()
        }
        return url
    }

    /// The vendored chunk at `key`, validated against its descriptor.
    func chunk(_ key: LocaleCatalogChunkKey) throws -> LocaleCatalogChunk {
        guard let record = manifest.record(for: key.locale),
              let descriptor = record.chunks.first(where: { $0.pack == key.pack }),
              let bytes = chunkBytes[key]
        else { throw TestFailure() }
        return try LocaleCatalogChunk.validate(
            LosslessJSONParser.parse(bytes),
            expectedLocale: key.locale,
            expectedFallback: record.fallback,
            expectedPack: key.pack,
            expectedKeys: descriptor.keys,
            expectedUnsupportedKeys: descriptor.unsupportedKeys
        ).get()
    }

    /// Every `cardNames` chunk URL the manifest lists.
    var cardNameURLs: Set<URL> {
        Set(chunkURLs.filter { $0.key.pack == "cardNames" }.values)
    }

    /// The manifest plus every chunk, minus `withheld`, with `overrides` replacing a body.
    func transport(
        withheld: Set<URL> = [],
        overrides: [URL: Data] = [:],
        failure: (any Error & Sendable)? = nil
    ) -> FixtureLocaleCatalogTransport {
        var responses = [manifestURL: response(data: manifestBytes, url: manifestURL)]
        for (key, url) in chunkURLs where !withheld.contains(url) {
            responses[url] = response(data: overrides[url] ?? chunkBytes[key] ?? Data(), url: url)
        }
        return FixtureLocaleCatalogTransport(responses: responses, failure: failure)
    }

    /// Exact bytes keyed by digest, as the loader hands them to the store.
    func bytesByDigest(_ keys: [LocaleCatalogChunkKey]) -> [String: Data] {
        var result: [String: Data] = [:]
        for key in keys {
            guard let bytes = chunkBytes[key] else { continue }
            result[LocaleCatalogLoader.sha256Hex(bytes)] = bytes
        }
        return result
    }

    func load(
        _ loader: LocaleCatalogLoader, locale: String
    ) async throws -> LocaleCatalogSnapshot {
        try await loader.load(
            advertisement: advertisement, profile: profile, preferredLanguages: [locale]
        ).get()
    }

    func loadDeferred(
        _ loader: LocaleCatalogLoader, snapshot: LocaleCatalogSnapshot
    ) async -> Result<LocaleCatalogSnapshot, LocaleCatalogFailure> {
        await loader.loadDeferredPacks(
            for: snapshot, advertisement: advertisement, profile: profile
        )
    }
}

extension LocaleCatalogSnapshot {
    /// The plain text `cardNames.<code>` renders to, or `nil` on a miss.
    func cardName(_ code: String) -> String? {
        guard case let .success(nodes) = LocaleCatalogResolver(snapshot: self).render(
            key: "cardNames.\(code)", variables: .object([:])
        ) else { return nil }
        return nodes.map(\.plainText).joined()
    }
}
