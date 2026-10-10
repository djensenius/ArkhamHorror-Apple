// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Create game catalog")
// swiftlint:disable:next type_body_length
struct GameLifecycleCreateCatalogTests {
    @Test("Night of the Zealot catalog contains campaign and three standalone scenarios")
    func nightOfTheZealotCatalogContent() {
        let catalog = CreateGameCatalog.default

        #expect(
            catalog.campaigns == [
                CreateGameCampaignOption(id: "01", title: "The Night of the Zealot"),
            ]
        )
        #expect(
            catalog.standaloneScenarios == [
                CreateGameScenarioOption(
                    id: "01104", title: "The Gathering", campaignID: "01"
                ),
                CreateGameScenarioOption(
                    id: "01120", title: "The Midnight Masks", campaignID: "01"
                ),
                CreateGameScenarioOption(
                    id: "01142", title: "The Devourer Below", campaignID: "01"
                ),
            ]
        )
    }

    @Test("Catalog display names do not expose raw server ids")
    func catalogLabelsHideRawIDs() {
        let catalog = CreateGameCatalog.default
        for campaign in catalog.campaigns {
            #expect(campaign.title != campaign.id)
            #expect(!campaign.title.contains(campaign.id))
        }
        for scenario in catalog.standaloneScenarios {
            #expect(scenario.title != scenario.id)
            #expect(!scenario.title.contains(scenario.id))
        }
    }

    @Test("Vendored campaign-catalog fixture decodes and maps to create choices")
    func vendoredCampaignCatalogFixtureDecodes() throws {
        let document = try loadVendoredCatalog()
        #expect(document.schemaVersion == "1.0.0")
        #expect(document.catalogRevision == "1.00000000000000000000000000000000")

        let catalog = CreateGameCatalog.from(document: document, resolver: nil)
        #expect(catalog.campaigns.map(\.id) == ["01", "02", "06"])
        #expect(catalog.campaigns[1].title == "catalogNames.campaigns.02.name")
        #expect(catalog.campaigns[1].returnTo?.id == "51")
        #expect(catalog.campaigns[1].recommendedOptions.map(\.id) == ["PlayersDoNotControlStoryAssetClues"]) // swiftlint:disable:this line_length
        #expect(catalog.campaigns[2].variants.map(\.id) == [
            "theDreamEaters", "theDreamQuest", "theWebOfDreams",
        ])

        let daisy = try #require(catalog.standaloneScenarios.first { $0.id == "90004" })
        #expect(daisy.requiredInvestigator == "Daisy Walker")
        #expect(daisy.requiredInvestigatorCodes == ["01002", "01502", "90001"])
        #expect(daisy.deckRequirements == [
            "Daisy Walker's deck must include at least 4 non-weakness Tome assets.",
        ])
        let labyrinths = try #require(catalog.standaloneScenarios.first { $0.id == "83001" })
        #expect(labyrinths.sideStoryCampaignID == "83")
        #expect(labyrinths.parts.map(\.id) == ["83001", "83016"])
        #expect(labyrinths.difficulties == [.standard, .hard])
    }

    @Test("Catalog names and create option labels resolve through a locale catalog")
    func catalogLabelsResolveThroughLocaleCatalog() throws {
        let resolver = Self.syntheticResolver(entries: [
            "catalogNames.campaigns.02.name": "Das Vermächtnis von Dunwich",
            "catalogNames.campaigns.02.returnTo.name": "Rückkehr zu: Das Vermächtnis von Dunwich",
            "catalogNames.sideStories.83001.name": "Die Labyrinthe des Irrsinns",
            "catalogNames.sideStories.83001.parts.83016.name": "Gruppe B",
            "create.recommendedOption.PlayersDoNotControlStoryAssetClues.title":
                "Storyvorteile nicht kontrollieren",
            "create.fullCampaignOption.theDreamQuest": "Die Traumreise",
        ])
        let document = try loadVendoredCatalog()
        let catalog = CreateGameCatalog.from(document: document, resolver: resolver)

        let dunwich = try #require(catalog.campaigns.first { $0.id == "02" })
        #expect(dunwich.title == "Das Vermächtnis von Dunwich")
        #expect(dunwich.returnTo?.title == "Rückkehr zu: Das Vermächtnis von Dunwich")
        #expect(dunwich.recommendedOptions.first?.label == "Storyvorteile nicht kontrollieren")
        let dreamEaters = try #require(catalog.campaigns.first { $0.id == "06" })
        #expect(dreamEaters.variants[1].label == "Die Traumreise")
        #expect(dreamEaters.variants[0].label == "create.fullCampaignOption.theDreamEaters")
        let labyrinths = try #require(catalog.standaloneScenarios.first { $0.id == "83001" })
        #expect(labyrinths.title == "Die Labyrinthe des Irrsinns")
        #expect(labyrinths.parts[1].title == "Gruppe B")
    }

    @Test("Synthetic catalog mirrors web hard-coded scenario rules")
    @MainActor
    func syntheticCatalogMirrorsWebRules() throws {
        let document = try syntheticCatalogDocument(campaignID: "09", sideStory: [
            "id": "85001",
            "nameKey": "catalogNames.sideStories.85001.name",
            "standaloneDifficulties": ["Standard", "Hard"],
            "returnToVariant": true,
        ])
        let catalog = CreateGameCatalog.from(document: document, resolver: nil)

        #expect(!catalog.standaloneScenarios.contains { $0.id == "09501" })
        let blob = try #require(catalog.standaloneScenarios.first { $0.id == "85001" })
        #expect(blob.returnToVariant)
        let model = CreateGameViewModel(
            catalog: catalog, mode: .standaloneScenario, selectedScenarioID: "85001"
        )
        model.useReturnTo = true
        #expect(model.selectedTitle == "The Blob That Ate Everything ELSE!")
        #expect(try model.makeRequest().options == [.flag(.playWithTheBlobThatAteEverythingElse)])
    }

    @Test("Malformed campaign-catalog structure fails closed")
    func malformedCatalogStructureFailsClosed() throws {
        let malformedObject: [String: Any] = [
            "schemaVersion": "1.0.0",
            "catalogRevision": "1.00000000000000000000000000000000",
            "endpoint": "/api/v1/arkham/campaign-catalog",
            "digestAlgorithm": "sha256",
            "campaigns": [:],
            "scenarios": [],
            "sideStories": [],
        ]
        let malformed = try JSONSerialization.data(withJSONObject: malformedObject)
        #expect(throws: (any Error).self) {
            _ = try ContractJSON.decode(CampaignCatalogDocument.self, from: malformed)
        }
    }

    @Test("Malformed individual campaign and scenario entries are skipped")
    func malformedEntriesAreSkipped() throws {
        var json = try jsonObject(from: vendoredCatalogBytes())
        var campaigns = try #require(json["campaigns"] as? [[String: Any]])
        campaigns.insert(["id": "broken-campaign"], at: 0)
        json["campaigns"] = campaigns
        var sideStories = try #require(json["sideStories"] as? [[String: Any]])
        sideStories.append(["id": "broken-side-story"])
        json["sideStories"] = sideStories
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])

        let document = try ContractJSON.decode(CampaignCatalogDocument.self, from: data)
        #expect(document.campaigns.map(\.id) == ["01", "02", "06"])
        #expect(document.sideStories.map(\.id) == ["90004", "83001"])
    }

    @Test("Create requests echo catalog ids and web create-game fields")
    @MainActor
    // swiftlint:disable:next function_body_length
    func createRequestsEchoCatalogIDs() throws {
        let document = try loadVendoredCatalog()
        let catalog = CreateGameCatalog.from(document: document, resolver: nil)
        let dunwich = CreateGameViewModel(catalog: catalog, selectedCampaignID: "02")
        var request = try dunwich.makeRequest()
        #expect(request.campaignOrScenario.campaignId == "02")
        #expect(request.campaignOrScenario.scenarioId == nil)
        #expect(request.strictAsIfAt == .value(false))
        #expect(request.asIfRuling == .value(.chapter1))
        #expect(request.options == [.flag(.playersDoNotControlStoryAssetClues)])
        var json = try encodedJSONObject(request)
        #expect(json["campaignId"] as? String == "02")
        #expect(json["scenarioId"] is NSNull)
        #expect(json["asIfRuling"] as? String == "chapter1")
        #expect(json["ultimatumsAndBoons"] is [Any])
        let expectedDunwichJSON = [
            "{\"achievementsEnabled\":true,\"asIfRuling\":\"chapter1\",",
            "\"campaignId\":\"02\",\"campaignName\":\"catalogNames.campaigns.02.name\",",
            "\"deckIds\":[null,null,null,null],\"difficulty\":\"Easy\",",
            "\"includeTarotReadings\":false,\"multiplayerVariant\":\"WithFriends\",",
            "\"options\":[{\"tag\":\"PlayersDoNotControlStoryAssetClues\"}],",
            "\"playerCount\":1,\"scenarioId\":null,\"strictAsIfAt\":false,",
            "\"ultimatumsAndBoons\":[]}",
        ].joined()
        let actualDunwichJSON = try encodedJSONString(request)
        #expect(actualDunwichJSON == expectedDunwichJSON)

        let sideStory = CreateGameViewModel(
            catalog: catalog, mode: .standaloneScenario, selectedScenarioID: "90004"
        )
        request = try sideStory.makeRequest()
        #expect(request.campaignOrScenario.campaignId == nil)
        #expect(request.campaignOrScenario.scenarioId == "90004")
        #expect(request.achievementsEnabled == .value(false))
        #expect(sideStory.selectedScenarioRequiresInvestigatorCode("c01002"))
        #expect(sideStory.selectedScenarioRequiresInvestigatorCode("01502"))
        #expect(!sideStory.selectedScenarioRequiresInvestigatorCode("01001"))
        let expectedSideStoryJSON = [
            "{\"achievementsEnabled\":false,\"asIfRuling\":\"chapter1\",",
            "\"campaignId\":null,\"campaignName\":\"catalogNames.sideStories.90004.name\",",
            "\"deckIds\":[null,null,null,null],\"difficulty\":\"Easy\",",
            "\"includeTarotReadings\":false,\"multiplayerVariant\":\"WithFriends\",",
            "\"options\":[],\"playerCount\":1,\"scenarioId\":\"90004\",",
            "\"strictAsIfAt\":false,\"ultimatumsAndBoons\":[]}",
        ].joined()
        let actualSideStoryJSON = try encodedJSONString(request)
        #expect(actualSideStoryJSON == expectedSideStoryJSON)

        let labyrinths = CreateGameViewModel(
            catalog: catalog, mode: .standaloneScenario, selectedScenarioID: "83001"
        )
        request = try labyrinths.makeRequest()
        #expect(request.campaignOrScenario.campaignId == "83")
        #expect(request.campaignOrScenario.scenarioId == nil)
        json = try encodedJSONObject(request)
        #expect(json["campaignId"] as? String == "83")
        #expect(json["scenarioId"] is NSNull)
        #expect(labyrinths.selectedSideStoryParts.map(\.id) == ["83001", "83016"])
        labyrinths.selectedSideStoryPartID = "83016"
        request = try labyrinths.makeRequest()
        #expect(request.campaignOrScenario.campaignId == nil)
        #expect(request.campaignOrScenario.scenarioId == "83016")
    }

    @Test("Create flow strings resolve in English and German bundles")
    func createFlowStringsResolveFromModuleBundle() throws {
        let keys = [
            "create.sideStoryMode",
            "create.sideStoryMode.accessibility",
            "create.bothScenarios",
            "create.requiresInvestigator",
            "create.blobElse.title",
            "create.blobElse.toggle",
        ]
        for locale in ["en", "de"] {
            let strings = try localizedStringsFile(locale: locale)
            for key in keys {
                let value = try localized(key: key, fallback: "__missing__", locale: locale)
                #expect(value != "__missing__", "Missing localized value for \(key) in \(locale)")
                #expect(
                    strings.contains(#""\#(key)""#),
                    "Missing literal key \(key) in \(locale) strings file"
                )
            }
        }
    }

    @Test("Campaign catalog service uses If-None-Match and cached bytes on 304")
    func serviceUsesETagCacheOn304() async throws {
        let url = ServerProfile.hosted.endpointURL(path: "/arkham/campaign-catalog")
        let transport = try CampaignCatalogQueuedTransport(responses: [
            (
                vendoredCatalogBytes(),
                httpResponse(url: url, status: 200, headers: ["ETag": "W/\"catalog-a\""])
            ),
            (Data(), httpResponse(url: url, status: 304, headers: ["ETag": "W/\"catalog-a\""])),
        ])
        let service = CampaignCatalogService(transport: transport)
        let first = try await service.load(on: .hosted)
        let second = try await service.load(on: .hosted)

        #expect(first == second)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "W/\"catalog-a\"")
    }

    @Test("Capabilities fixture advertises the campaign catalog metadata")
    func capabilitiesAdvertiseCampaignCatalog() throws {
        let url = try #require(Bundle.module.url(
            forResource: "capabilities", withExtension: "json", subdirectory: "Fixtures/Contract"
        ))
        let capabilities = try ContractJSON.decode(ServerCapabilities.self, from: Data(contentsOf: url)) // swiftlint:disable:this line_length
        #expect(capabilities.capabilities.contains(CampaignCatalogAdvertisement.capabilityIdentifier)) // swiftlint:disable:this line_length
        #expect(capabilities.campaignCatalog?.endpoint == "/api/v1/arkham/campaign-catalog")
        #expect(capabilities.campaignCatalog?.catalogRevision == "1.0123456789abcdef0123456789abcdef") // swiftlint:disable:this line_length
    }

    private func loadVendoredCatalog() throws -> CampaignCatalogDocument {
        try ContractJSON.decode(CampaignCatalogDocument.self, from: vendoredCatalogBytes())
    }

    private func vendoredCatalogBytes() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "campaign-catalog", withExtension: "json", subdirectory: "Fixtures/Contract" // swiftlint:disable:this line_length
        ))
        return try Data(contentsOf: url)
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func encodedJSONObject(_ request: CreateGameRequest) throws -> [String: Any] {
        try jsonObject(from: ContractJSON.encode(request))
    }

    private func encodedJSONString(_ request: CreateGameRequest) throws -> String {
        try #require(String(data: ContractJSON.encode(request), encoding: .utf8))
    }

    private func syntheticCatalogDocument(
        campaignID: String,
        sideStory: [String: Any]
    ) throws -> CampaignCatalogDocument {
        var json = try jsonObject(from: vendoredCatalogBytes())
        json["campaigns"] = [[
            "id": campaignID,
            "nameKey": "catalogNames.campaigns.\(campaignID).name",
        ]]
        json["scenarios"] = [[
            "id": "09501",
            "nameKey": "catalogNames.scenarios.09501.name",
            "campaign": campaignID,
        ]]
        json["sideStories"] = [sideStory]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return try ContractJSON.decode(CampaignCatalogDocument.self, from: data)
    }

    private static func syntheticResolver(entries: [String: String]) -> LocaleCatalogResolver {
        let descriptors = [LocaleCatalogChunkDescriptor(
            pack: "create", path: "/locale-catalog/c/test.json", bytes: 1,
            sha256: String(repeating: "a", count: 64), keys: entries.count, unsupportedKeys: 0
        )]
        let manifest = LocaleCatalogManifest(
            catalogRevision: "1.synthetic000000000000000000000000",
            defaultLocale: "en",
            locales: [LocaleCatalogLocaleRecord(
                locale: "en", fallback: nil, chunks: descriptors, keys: entries.count, bytes: 1
            )],
            languageResolution: ["en": "en"],
            totals: LocaleCatalogTotals(
                locales: 1, chunks: 1, bytes: 1, keys: entries.count, unsupportedKeys: 0
            )
        )
        let chunk = LocaleCatalogChunk(
            locale: "en",
            fallback: nil,
            pack: "create",
            entries: entries.mapValues { .message(nodes: [.text($0)], variables: []) }
        )
        let identity = LocaleCatalogIdentity(
            endpoint: URL(string: "https://catalog.example.test/locale-catalog/manifest.json")!,
            catalogRevision: manifest.catalogRevision,
            locale: "en",
            manifestSha256: String(repeating: "b", count: 64)
        )
        return LocaleCatalogResolver(
            snapshot: LocaleCatalogSnapshot(
                identity: identity,
                manifest: manifest,
                chunks: [LocaleCatalogChunkKey(locale: "en", pack: "create"): chunk]
            )
        )
    }

    private func localized(key: String, fallback: String, locale: String) throws -> String {
        let bundle = try moduleBundle(locale: locale)
        return NSLocalizedString(key, bundle: bundle, value: fallback, comment: "")
    }

    private func moduleBundle(locale: String) throws -> Bundle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/ArkhamHorrorShared/Localization")
            .appending(path: "\(locale).lproj")
        return try #require(Bundle(url: url))
    }

    private func localizedStringsFile(locale: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/ArkhamHorrorShared/Localization")
            .appending(path: "\(locale).lproj/Localizable.strings")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private actor CampaignCatalogQueuedTransport: HTTPTransport {
    private var responses: [(Data, URLResponse)]
    private(set) var requests: [URLRequest] = []

    init(responses: [(Data, URLResponse)]) {
        self.responses = responses
    }

    nonisolated func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await record(request)
    }

    private func record(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        return responses.removeFirst()
    }
}

private func httpResponse(url: URL, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse { // swiftlint:disable:this line_length
    HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}
