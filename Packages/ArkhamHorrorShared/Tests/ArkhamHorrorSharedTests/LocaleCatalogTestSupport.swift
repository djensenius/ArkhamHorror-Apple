@testable import ArkhamHorrorShared
import Foundation

struct SyntheticLocaleCatalogDocuments {
    let profile: ServerProfile
    let advertisement: LocaleCatalogAdvertisement
    let manifestURL: URL
    let chunkURL: URL
    let manifestBytes: Data
    let chunkBytes: Data

    // swiftlint:disable:next function_body_length
    static func make(
        manifestPath: String = "/locale-catalog/manifest.json",
        declaredChunkBytes: Int? = nil,
        pack: String = "story",
        entryKeys: [String] = ["story.body"],
        chunkEntries: String = """
        {"story.body":{"form":"message","nodes":[{"type":"text","value":"Synthetic body"}],\
        "variables":[]}}
        """
    ) throws -> SyntheticLocaleCatalogDocuments {
        let profile = try ServerProfile.custom(
            displayName: "Synthetic catalog",
            rawURL: "https://catalog.example.test/profile-prefix"
        )
        let revision = "1.0123456789abcdef0123456789abcdef"
        let chunkBytes = Data(
            """
            {"schemaVersion":"1.0.0","locale":"en","fallback":null,"pack":"\(pack)","entries":\
            \(chunkEntries)}
            """.utf8
        )
        let chunkDigest = LocaleCatalogLoader.sha256Hex(chunkBytes)
        let expectedChunkBytes = declaredChunkBytes ?? chunkBytes.count
        let fixtureKeyBytes = try JSONEncoder().encode(entryKeys)
        guard let fixtureKeys = String(data: fixtureKeyBytes, encoding: .utf8) else {
            throw TestFailure()
        }
        let manifestBytes = Data(
            """
            {"schemaVersion":"1.0.0","catalogRevision":"\(revision)",\
            "basePath":"/locale-catalog","manifestPath":"/locale-catalog/manifest.json",\
            "revisionManifestPath":"/locale-catalog/r/\(revision)/manifest.json",\
            "chunkPathPrefix":"/locale-catalog/c/","digestAlgorithm":"sha256",\
            "defaultLocale":"en","languageResolution":[{"tag":"en","locale":"en"}],\
            "locales":[{"locale":"en","fallback":null,"chunks":[{"pack":"\(pack)",\
            "path":"/locale-catalog/c/\(chunkDigest).json","bytes":\(expectedChunkBytes),\
            "sha256":"\(chunkDigest)","keys":\(entryKeys.count),"unsupportedKeys":0}],\
            "keys":\(entryKeys.count),\
            "bytes":\(expectedChunkBytes)}],"totals":{"locales":1,"chunks":1,\
            "bytes":\(expectedChunkBytes),"keys":\(entryKeys.count),"unsupportedKeys":0},\
            "backend":{"artifactPath":"fixtures/synthetic.json","artifactSha256":"\(hex)",\
            "sourceSha256":"\(hex)","emittedKeys":\(entryKeys.count),\
            "requiredKeys":\(entryKeys.count),\
            "untranslatedKeys":[],"variableGaps":[],"dynamicSites":0,\
            "unknownVariableTypes":[]},\
            "provenance":{"sha256":"\(hex)","outputSha256":"\(hex)",\
            "generator":{"name":"arkham-locale-catalog","version":"1.0.0"},\
            "contractRevision":"0.1.23","fixtureKeys":\(fixtureKeys),\
            "localeSourceFiles":1,"localeSourcesSha256":"\(hex)",\
            "schemasSha256":"\(hex)","generatorSha256":"\(hex)"}}
            """.utf8
        )
        guard let manifestLocation = LocaleCatalogManifestURL.parse(manifestPath) else {
            throw TestFailure()
        }
        let advertisement = LocaleCatalogAdvertisement(
            manifestURL: manifestLocation,
            catalogRevision: revision,
            schemaVersion: LocaleCatalogLimits.schemaVersion,
            defaultLocale: "en",
            supportedLocales: ["en"],
            manifestSha256: LocaleCatalogLoader.sha256Hex(manifestBytes)
        )
        guard let manifestURL = advertisement.resolvedManifestURL(for: profile),
              let chunkURL = advertisement.resolvedChunkURL(
                  path: LocaleCatalogGrammar.chunkPath(forDigest: chunkDigest),
                  for: profile
              )
        else {
            throw TestFailure()
        }
        return SyntheticLocaleCatalogDocuments(
            profile: profile,
            advertisement: advertisement,
            manifestURL: manifestURL,
            chunkURL: chunkURL,
            manifestBytes: manifestBytes,
            chunkBytes: chunkBytes
        )
    }

    static var hex: String {
        String(repeating: "a", count: 64)
    }

    func response(
        data: Data,
        status: Int = 200,
        contentType: String? = "application/json; charset=utf-8",
        contentTypeOptions: String? = "nosniff",
        url: URL? = nil
    ) -> LocaleCatalogResponse {
        LocaleCatalogResponse(
            statusCode: status,
            contentType: contentType,
            contentTypeOptions: contentTypeOptions,
            url: url,
            data: data
        )
    }

    func loader() -> LocaleCatalogLoader {
        LocaleCatalogLoader(transport: FixtureLocaleCatalogTransport(responses: [
            manifestURL: response(data: manifestBytes, url: manifestURL),
            chunkURL: response(data: chunkBytes, url: chunkURL),
        ]))
    }

    func loadSnapshot(
        preferredLanguages: [String] = ["en"]
    ) async throws -> LocaleCatalogSnapshot {
        try await loader().load(
            advertisement: advertisement,
            profile: profile,
            preferredLanguages: preferredLanguages
        ).get()
    }
}

actor FixtureLocaleCatalogTransport: LocaleCatalogTransporting {
    private var responses: [URL: LocaleCatalogResponse]
    private var sequences: [URL: [LocaleCatalogResponse]]
    private var failure: (any Error & Sendable)?
    private let cancellationRequestNumber: Int?
    private(set) var requests: [URL] = []

    init(
        responses: [URL: LocaleCatalogResponse],
        sequences: [URL: [LocaleCatalogResponse]] = [:],
        failure: (any Error & Sendable)? = nil,
        cancellationRequestNumber: Int? = nil
    ) {
        self.responses = responses
        self.sequences = sequences
        self.failure = failure
        self.cancellationRequestNumber = cancellationRequestNumber
    }

    func fetch(_ url: URL, maxBytes _: Int) async throws -> LocaleCatalogResponse {
        requests.append(url)
        if cancellationRequestNumber == requests.count {
            throw CancellationError()
        }
        if let failure {
            throw failure
        }
        if var sequence = sequences[url], !sequence.isEmpty {
            let response = sequence.removeFirst()
            sequences[url] = sequence
            return response
        }
        guard let response = responses[url] else {
            throw LocaleCatalogFailure.transportFailure
        }
        return response
    }

    func replaceResponse(_ response: LocaleCatalogResponse, for url: URL) {
        responses[url] = response
    }
}
