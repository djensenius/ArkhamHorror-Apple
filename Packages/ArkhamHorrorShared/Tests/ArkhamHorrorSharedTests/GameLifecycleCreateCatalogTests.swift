@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Create game catalog")
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
        let labyrinths = try #require(catalog.standaloneScenarios.first { $0.id == "83001" })
        #expect(labyrinths.sideStoryCampaignID == "83")
        #expect(labyrinths.difficulties == [.standard, .hard])
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
    func createRequestsEchoCatalogIDs() throws {
        let catalog = try CreateGameCatalog.from(document: loadVendoredCatalog(), resolver: nil)
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

        let sideStory = CreateGameViewModel(
            catalog: catalog, mode: .standaloneScenario, selectedScenarioID: "90004"
        )
        request = try sideStory.makeRequest()
        #expect(request.campaignOrScenario.campaignId == nil)
        #expect(request.campaignOrScenario.scenarioId == "90004")
        #expect(request.achievementsEnabled == .value(false))

        let labyrinths = CreateGameViewModel(
            catalog: catalog, mode: .standaloneScenario, selectedScenarioID: "83001"
        )
        request = try labyrinths.makeRequest()
        #expect(request.campaignOrScenario.campaignId == "83")
        #expect(request.campaignOrScenario.scenarioId == nil)
        json = try encodedJSONObject(request)
        #expect(json["campaignId"] as? String == "83")
        #expect(json["scenarioId"] is NSNull)
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
