@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Locale catalog loader")
struct LocaleCatalogLoaderTests {
    private func loader(
        _ documents: SyntheticLocaleCatalogDocuments,
        manifest: LocaleCatalogResponse? = nil,
        chunk: LocaleCatalogResponse? = nil
    ) -> LocaleCatalogLoader {
        let transport = FixtureLocaleCatalogTransport(responses: [
            documents.manifestURL: manifest
                ?? documents.response(data: documents.manifestBytes, url: documents.manifestURL),
            documents.chunkURL: chunk
                ?? documents.response(data: documents.chunkBytes, url: documents.chunkURL),
        ])
        return LocaleCatalogLoader(transport: transport)
    }

    @Test("Loader accepts a complete manifest and exact chunk identity")
    func loaderAcceptsCompleteSyntheticCatalog() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let result = await loader(documents).load(
            advertisement: documents.advertisement,
            profile: documents.profile,
            preferredLanguages: ["en-US"]
        )
        let snapshot = try result.get()
        #expect(snapshot.identity.catalogRevision == documents.advertisement.catalogRevision)
        #expect(snapshot.localeChain == ["en"])
        #expect(LocaleCatalogResolver(snapshot: snapshot).render(
            key: "story.body", variables: .object([:])
        ) == .success([.text("Synthetic body")]))
    }

    @Test("Loader rejects manifest digest, response policy, and transport failures")
    // swiftlint:disable:next function_body_length
    func loaderRejectsManifestTransportFailures() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let cases: [(LocaleCatalogResponse, LocaleCatalogFailure)] = [
            (
                documents.response(data: Data("wrong".utf8), url: documents.manifestURL),
                .manifestDigestMismatch
            ),
            (
                documents.response(
                    data: documents.manifestBytes, status: 503, url: documents.manifestURL
                ),
                .unexpectedStatus(503)
            ),
            (
                documents.response(
                    data: documents.manifestBytes,
                    contentType: "text/html",
                    url: documents.manifestURL
                ),
                .unacceptableContentType
            ),
            (
                documents.response(
                    data: documents.manifestBytes,
                    contentTypeOptions: nil,
                    url: documents.manifestURL
                ),
                .unacceptableContentType
            ),
            (
                documents.response(
                    data: documents.manifestBytes,
                    url: URL(string: "https://redirect.example.test/manifest.json")
                ),
                .redirected
            ),
        ]
        for (response, expected) in cases {
            let result = await loader(documents, manifest: response).load(
                advertisement: documents.advertisement,
                profile: documents.profile,
                preferredLanguages: ["en"]
            )
            #expect(result == .failure(expected))
        }

        let timeoutLoader = LocaleCatalogLoader(
            transport: FixtureLocaleCatalogTransport(
                responses: [:],
                failure: URLError(.timedOut)
            )
        )
        let timeout = await timeoutLoader.load(
            advertisement: documents.advertisement,
            profile: documents.profile,
            preferredLanguages: ["en"]
        )
        #expect(timeout == .failure(.transportFailure))
    }

    @Test("Loader rejects a chunk whose bytes or identity do not match the manifest")
    func loaderRejectsInvalidChunk() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let mismatchedBytes = documents.response(
            data: Data("{}".utf8), url: documents.chunkURL
        )
        let digestResult = await loader(documents, chunk: mismatchedBytes).load(
            advertisement: documents.advertisement,
            profile: documents.profile,
            preferredLanguages: ["en"]
        )
        #expect(digestResult == .failure(.chunkDigestMismatch))

        let invalidIdentity = Data(
            """
            {"schemaVersion":"1.0.0","locale":"en","fallback":null,"pack":"core","entries":{}}
            """.utf8
        )
        let identityResult = await loader(
            documents,
            chunk: documents.response(data: invalidIdentity, url: documents.chunkURL)
        ).load(
            advertisement: documents.advertisement,
            profile: documents.profile,
            preferredLanguages: ["en"]
        )
        #expect(identityResult == .failure(.chunkDigestMismatch))

        let wrongSize = try SyntheticLocaleCatalogDocuments.make(
            declaredChunkBytes: documents.chunkBytes.count + 1
        )
        let sizeResult = await loader(wrongSize).load(
            advertisement: wrongSize.advertisement,
            profile: wrongSize.profile,
            preferredLanguages: ["en"]
        )
        #expect(sizeResult == .failure(.chunkDigestMismatch))
    }

    @Test("Loader rejects duplicate-key JSON and closed manifest mismatches")
    func loaderRejectsMalformedManifestClosure() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let duplicate = Data(
            """
            {"schemaVersion":"1.0.0","schemaVersion":"1.0.0"}
            """.utf8
        )
        let malformedAdvertisement = LocaleCatalogAdvertisement(
            manifestURL: documents.advertisement.manifestURL,
            catalogRevision: documents.advertisement.catalogRevision,
            schemaVersion: documents.advertisement.schemaVersion,
            defaultLocale: documents.advertisement.defaultLocale,
            supportedLocales: documents.advertisement.supportedLocales,
            manifestSha256: LocaleCatalogLoader.sha256Hex(duplicate)
        )
        let parserResult = await loader(
            documents,
            manifest: documents.response(data: duplicate, url: documents.manifestURL)
        ).load(
            advertisement: malformedAdvertisement,
            profile: documents.profile,
            preferredLanguages: ["en"]
        )
        #expect(parserResult == .failure(.malformedJSON))

        let closedButWrong = Data("{}".utf8)
        let closedAdvertisement = LocaleCatalogAdvertisement(
            manifestURL: documents.advertisement.manifestURL,
            catalogRevision: documents.advertisement.catalogRevision,
            schemaVersion: documents.advertisement.schemaVersion,
            defaultLocale: documents.advertisement.defaultLocale,
            supportedLocales: documents.advertisement.supportedLocales,
            manifestSha256: LocaleCatalogLoader.sha256Hex(closedButWrong)
        )
        let closedResult = await loader(
            documents,
            manifest: documents.response(data: closedButWrong, url: documents.manifestURL)
        ).load(
            advertisement: closedAdvertisement,
            profile: documents.profile,
            preferredLanguages: ["en"]
        )
        #expect(closedResult == .failure(.malformedManifest))
    }

    @Test("A chunk 404 gets one authorized manifest refresh and one bounded retry")
    func chunk404RecoversOnce() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let manifest = documents.response(data: documents.manifestBytes, url: documents.manifestURL)
        let chunk404 = documents.response(data: Data(), status: 404, url: documents.chunkURL)
        let chunk = documents.response(data: documents.chunkBytes, url: documents.chunkURL)
        let transport = FixtureLocaleCatalogTransport(
            responses: [:],
            sequences: [
                documents.manifestURL: [manifest, manifest],
                documents.chunkURL: [chunk404, chunk],
            ]
        )
        let result = await LocaleCatalogLoader(transport: transport).load(
            advertisement: documents.advertisement,
            profile: documents.profile,
            preferredLanguages: ["en"]
        )
        #expect(try result.get().isComplete)
        #expect(await transport.requests == [
            documents.manifestURL, documents.chunkURL,
            documents.manifestURL, documents.chunkURL,
        ])
    }

    @Test("Recovery fails closed on an unauthorized refresh, repeated 404, or cancellation")
    func chunk404RecoveryFailures() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let manifest = documents.response(data: documents.manifestBytes, url: documents.manifestURL)
        let notAuthorized = documents.response(
            data: Data("not the advertised manifest".utf8), url: documents.manifestURL
        )
        let missing = documents.response(data: Data(), status: 404, url: documents.chunkURL)
        let unauthorizedTransport = FixtureLocaleCatalogTransport(
            responses: [:],
            sequences: [
                documents.manifestURL: [manifest, notAuthorized],
                documents.chunkURL: [missing],
            ]
        )
        let unauthorized = await LocaleCatalogLoader(transport: unauthorizedTransport).load(
            advertisement: documents.advertisement,
            profile: documents.profile,
            preferredLanguages: ["en"]
        )
        #expect(unauthorized == .failure(.manifestDigestMismatch))

        let repeatedTransport = FixtureLocaleCatalogTransport(
            responses: [:],
            sequences: [
                documents.manifestURL: [manifest, manifest],
                documents.chunkURL: [missing, missing],
            ]
        )
        let repeated = await LocaleCatalogLoader(transport: repeatedTransport).load(
            advertisement: documents.advertisement,
            profile: documents.profile,
            preferredLanguages: ["en"]
        )
        #expect(repeated == .failure(.unexpectedStatus(404)))
        #expect(await (repeatedTransport.requests).count == 4)

        let cancelledTransport = FixtureLocaleCatalogTransport(
            responses: [:],
            sequences: [documents.manifestURL: [manifest], documents.chunkURL: [missing]],
            cancellationRequestNumber: 3
        )
        let cancelled = await LocaleCatalogLoader(transport: cancelledTransport).load(
            advertisement: documents.advertisement,
            profile: documents.profile,
            preferredLanguages: ["en"]
        )
        #expect(cancelled == .failure(.transportFailure))
        #expect(await (cancelledTransport.requests).count == 3)
    }
}
