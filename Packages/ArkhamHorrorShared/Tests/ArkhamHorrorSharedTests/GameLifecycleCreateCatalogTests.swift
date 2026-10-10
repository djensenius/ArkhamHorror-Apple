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

        let catalog = CreateGameCatalog.from(document: document, resolver: nil, includeBeta: true)
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
        let catalog = CreateGameCatalog.from(
            document: document, resolver: resolver, includeBeta: true
        )

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
        let resolver = Self.syntheticResolver(entries: [
            "catalogNames.campaigns.02.name": "The Dunwich Legacy",
            "catalogNames.sideStories.90004.name": "Bad Blood",
            "catalogNames.sideStories.83001.name": "The Labyrinths of Lunacy",
            "catalogNames.sideStories.83001.parts.83016.name": "Group B",
            "create.recommendedOption.PlayersDoNotControlStoryAssetClues.title":
                "Players do not control story asset clues",
        ])
        let catalog = CreateGameCatalog.from(
            document: document, resolver: resolver, includeBeta: true
        )
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
            "\"campaignId\":\"02\",\"campaignName\":\"The Dunwich Legacy\",",
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
            "\"campaignId\":null,\"campaignName\":\"Bad Blood\",",
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

    @Test("Unresolved catalog name keys cannot be sent as campaignName")
    @MainActor
    func unresolvedCatalogNameKeysCannotBeSentAsCampaignName() throws {
        let document = try loadVendoredCatalog()
        let catalog = CreateGameCatalog.from(document: document, resolver: nil)
        let viewModel = CreateGameViewModel(catalog: catalog, selectedCampaignID: "02")

        #expect(viewModel.selectedTitle == "catalogNames.campaigns.02.name")
        #expect(viewModel.requiresCustomName)
        #expect(!viewModel.canSubmit)
        do {
            _ = try viewModel.makeRequest()
            Issue.record("Unresolved catalog key should require a custom name")
        } catch let failure as CreateGameViewModel.Failure {
            #expect(failure == .unresolvedCatalogName("catalogNames.campaigns.02.name"))
        }

        viewModel.customName = "Local table name"
        let request = try viewModel.makeRequest()
        #expect(request.campaignName == "Local table name")
    }

    @Test("Live catalog display rules match web filtering")
    func liveCatalogDisplayRulesMatchWebFiltering() throws {
        let document = try loadLiveCatalog()
        let standardCatalog = CreateGameCatalog.from(document: document, resolver: nil)

        #expect(!standardCatalog.standaloneScenarios.contains { $0.id == "04344" })
        for prelude in ["10704", "10677a", "10679a", "10679b"] {
            #expect(!standardCatalog.standaloneScenarios.contains { $0.id == prelude })
        }
        #expect(!standardCatalog.campaigns.contains { $0.id == "11" })
        #expect(!standardCatalog.campaigns.contains { $0.id == "13" })
        #expect(!standardCatalog.standaloneScenarios.contains { $0.id == "11501" })
        #expect(!standardCatalog.standaloneScenarios.contains { $0.id == "70001" })

        let betaCatalog = CreateGameCatalog.from(
            document: document, resolver: nil, includeBeta: true
        )
        #expect(betaCatalog.campaigns.contains { $0.id == "11" })
        #expect(!betaCatalog.campaigns.contains { $0.id == "13" })
        #expect(betaCatalog.standaloneScenarios.contains { $0.id == "11501" })
        #expect(betaCatalog.standaloneScenarios.contains { $0.id == "70001" })
        #expect(!betaCatalog.standaloneScenarios.contains { $0.id == "04344" })
    }

    @Test("Synthetic alpha beta and dev gates match native web parity policy")
    func syntheticDisplayGatesMatchNativePolicy() throws {
        var json = try jsonObject(from: vendoredCatalogBytes())
        json["campaigns"] = [
            ["id": "01", "nameKey": "catalogNames.campaigns.01.name"],
            ["id": "11", "nameKey": "catalogNames.campaigns.11.name", "beta": true],
            ["id": "13", "nameKey": "catalogNames.campaigns.13.name", "alpha": true],
            ["id": "98", "nameKey": "catalogNames.campaigns.98.name", "dev": true],
            [
                "id": "02", "nameKey": "catalogNames.campaigns.02.name",
                "returnTo": [
                    "id": "51", "nameKey": "catalogNames.campaigns.02.returnTo.name",
                    "alpha": true,
                ],
            ],
        ]
        json["scenarios"] = [
            ["id": "01104", "nameKey": "catalogNames.scenarios.01104.name", "campaign": "01"],
            ["id": "11501", "nameKey": "catalogNames.scenarios.11501.name", "campaign": "11"],
            ["id": "98501", "nameKey": "catalogNames.scenarios.98501.name", "campaign": "98"],
            [
                "id": "01501", "nameKey": "catalogNames.scenarios.01501.name",
                "campaign": "01", "dev": true,
            ],
        ]
        json["sideStories"] = [
            ["id": "70001", "nameKey": "catalogNames.sideStories.70001.name", "beta": true],
            ["id": "99001", "nameKey": "catalogNames.sideStories.99001.name", "dev": true],
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let document = try ContractJSON.decode(CampaignCatalogDocument.self, from: data)

        let standard = CreateGameCatalog.from(document: document, resolver: nil)
        #expect(standard.campaigns.map(\.id) == ["01", "02"])
        #expect(standard.campaigns.first { $0.id == "02" }?.returnTo == nil)
        #expect(!standard.standaloneScenarios.contains { $0.id == "11501" })
        #expect(!standard.standaloneScenarios.contains { $0.id == "01501" })
        #expect(!standard.standaloneScenarios.contains { $0.id == "70001" })

        let beta = CreateGameCatalog.from(document: document, resolver: nil, includeBeta: true)
        #expect(beta.campaigns.map(\.id) == ["01", "11", "02"])
        #expect(beta.standaloneScenarios.contains { $0.id == "11501" })
        #expect(beta.standaloneScenarios.contains { $0.id == "70001" })
        #expect(!beta.standaloneScenarios.contains { $0.id == "98501" })
        #expect(!beta.standaloneScenarios.contains { $0.id == "99001" })
    }

    @Test("Standalone request JSON matches web defaults for live catalog cases")
    @MainActor
    // swiftlint:disable:next function_body_length
    func standaloneRequestJSONMatchesWebDefaultsForLiveCatalogCases() throws {
        let document = try loadLiveCatalog()
        let resolver = Self.syntheticResolver(entries: [
            "catalogNames.scenarios.04043.name": "The Untamed Wilds",
            "catalogNames.scenarios.11501.name": "Written in Rock",
            "catalogNames.sideStories.85001.name": "The Blob That Ate Everything",
            "create.recommendedOption.PlayersDoNotControlStoryAssetClues.title":
                "Players do not control story asset clues",
        ])
        let catalog = CreateGameCatalog.from(
            document: document, resolver: resolver, includeBeta: true
        )

        let forgottenAge = CreateGameViewModel(
            catalog: catalog, mode: .standaloneScenario, selectedScenarioID: "04043"
        )
        var request = try forgottenAge.makeRequest()
        #expect(request.strictAsIfAt == .value(false))
        #expect(request.asIfRuling == .value(.chapter1))
        #expect(request.options == [.flag(.playersDoNotControlStoryAssetClues)])
        #expect(try encodedJSONString(request) == [
            "{\"achievementsEnabled\":false,\"asIfRuling\":\"chapter1\",",
            "\"campaignId\":null,\"campaignName\":\"The Untamed Wilds\",",
            "\"deckIds\":[null,null,null,null],\"difficulty\":\"Easy\",",
            "\"includeTarotReadings\":false,\"multiplayerVariant\":\"WithFriends\",",
            "\"options\":[{\"tag\":\"PlayersDoNotControlStoryAssetClues\"}],",
            "\"playerCount\":1,\"scenarioId\":\"04043\",\"strictAsIfAt\":false,",
            "\"ultimatumsAndBoons\":[]}",
        ].joined())

        let drownedCity = CreateGameViewModel(
            catalog: catalog, mode: .standaloneScenario, selectedScenarioID: "11501"
        )
        request = try drownedCity.makeRequest()
        #expect(request.strictAsIfAt == .value(true))
        #expect(request.asIfRuling == .value(.chapter2))
        #expect(try encodedJSONString(request) == [
            "{\"achievementsEnabled\":false,\"asIfRuling\":\"chapter2\",",
            "\"campaignId\":null,\"campaignName\":\"Written in Rock\",",
            "\"deckIds\":[null,null,null,null],\"difficulty\":\"Easy\",",
            "\"includeTarotReadings\":false,\"multiplayerVariant\":\"WithFriends\",",
            "\"options\":[],\"playerCount\":1,\"scenarioId\":\"11501\",",
            "\"strictAsIfAt\":true,\"ultimatumsAndBoons\":[]}",
        ].joined())

        let blob = CreateGameViewModel(
            catalog: catalog, mode: .standaloneScenario, selectedScenarioID: "85001"
        )
        blob.useReturnTo = true
        request = try blob.makeRequest()
        #expect(request.difficulty == .standard)
        #expect(request.options == [.flag(.playWithTheBlobThatAteEverythingElse)])
        #expect(try encodedJSONString(request) == [
            "{\"achievementsEnabled\":false,\"asIfRuling\":\"chapter1\",",
            "\"campaignId\":null,\"campaignName\":\"The Blob That Ate Everything ELSE!\",",
            "\"deckIds\":[null,null,null,null],\"difficulty\":\"Standard\",",
            "\"includeTarotReadings\":false,\"multiplayerVariant\":\"WithFriends\",",
            "\"options\":[{\"tag\":\"PlayWithTheBlobThatAteEverythingElse\"}],",
            "\"playerCount\":1,\"scenarioId\":\"85001\",\"strictAsIfAt\":false,",
            "\"ultimatumsAndBoons\":[]}",
        ].joined())
    }

    @Test("Synthetic chapter and side-story difficulty rules match web")
    @MainActor
    func syntheticChapterAndSideStoryDifficultyRulesMatchWeb() throws {
        var json = try jsonObject(from: vendoredCatalogBytes())
        json["campaigns"] = [[
            "id": "12",
            "chapter": 1,
            "nameKey": "catalogNames.campaigns.12.name",
        ]]
        json["scenarios"] = [[
            "id": "12501",
            "nameKey": "catalogNames.scenarios.12501.name",
            "campaign": "12",
        ]]
        json["sideStories"] = [[
            "id": "99001",
            "nameKey": "catalogNames.sideStories.99001.name",
        ]]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let resolver = Self.syntheticResolver(entries: [
            "catalogNames.scenarios.12501.name": "Explicit Chapter One Scenario",
            "catalogNames.sideStories.99001.name": "No Difficulty Side Story",
        ])
        let document = try ContractJSON.decode(CampaignCatalogDocument.self, from: data)
        let catalog = CreateGameCatalog.from(document: document, resolver: resolver)

        let scenario = CreateGameViewModel(
            catalog: catalog, mode: .standaloneScenario, selectedScenarioID: "12501"
        )
        #expect(try scenario.makeRequest().strictAsIfAt == .value(false))

        let sideStory = CreateGameViewModel(
            catalog: catalog, mode: .standaloneScenario, selectedScenarioID: "99001"
        )
        #expect(sideStory.availableDifficulties == [])
        #expect(try sideStory.makeRequest().difficulty == .easy)
    }

    @Test("Create flow strings resolve in English and German bundles")
    func createFlowStringsResolveFromModuleBundle() throws {
        let keysByLocale = try Dictionary(
            uniqueKeysWithValues: ["en", "de"].map { locale in
                try (locale, localizedStringKeys(locale: locale))
            }
        )
        let keyPrefixes = ["create.", "catalogNames."]
        let keys = keysByLocale.values
            .flatMap(\.self)
            .filter { key in keyPrefixes.contains { key.hasPrefix($0) } }
        #expect(!keys.isEmpty)
        for locale in ["en", "de"] {
            let localeKeys = try #require(keysByLocale[locale])
            for key in Set(keys).sorted() {
                #expect(localeKeys.contains(key), "Missing literal key \(key) in \(locale)")
                let value = try localized(key: key, fallback: "__missing__", locale: locale)
                #expect(value != "__missing__", "Missing localized value for \(key) in \(locale)")
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
        let advertisement = CampaignCatalogAdvertisement(
            endpoint: "/api/v1/arkham/campaign-catalog",
            catalogRevision: "1.00000000000000000000000000000000",
            schemaVersion: "1.0.0",
            digestAlgorithm: "sha256"
        )
        let first = try await service.load(on: .hosted, advertisement: advertisement)
        let second = try await service.load(on: .hosted, advertisement: advertisement)

        #expect(first == second)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "W/\"catalog-a\"")
    }

    @Test("Campaign catalog service keys cache entries by advertised catalog revision")
    func serviceCacheUsesAdvertisedCatalogRevision() async throws {
        let url = ServerProfile.hosted.endpointURL(path: "/arkham/campaign-catalog")
        let revisionA = "1.00000000000000000000000000000000"
        let revisionB = "1.11111111111111111111111111111111"
        let transport = try CampaignCatalogQueuedTransport(responses: [
            (
                vendoredCatalogBytes(),
                httpResponse(url: url, status: 200, headers: ["ETag": "W/\"catalog-a\""])
            ),
            (
                catalogBytes(revision: revisionB),
                httpResponse(url: url, status: 200, headers: ["ETag": "W/\"catalog-b\""])
            ),
            (Data(), httpResponse(url: url, status: 304, headers: ["ETag": "W/\"catalog-a\""])),
        ])
        let service = CampaignCatalogService(transport: transport)
        _ = try await service.load(on: .hosted, advertisement: advertisement(revision: revisionA))
        _ = try await service.load(on: .hosted, advertisement: advertisement(revision: revisionB))
        _ = try await service.load(on: .hosted, advertisement: advertisement(revision: revisionA))

        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[2].value(forHTTPHeaderField: "If-None-Match") == "W/\"catalog-a\"")
    }

    @Test("Malformed campaign catalog metadata disables feature detection")
    func malformedCampaignCatalogMetadataDisablesFeatureDetection() throws {
        let data = Data("""
        {
          "schemaRevision": "0.1.52",
          "status": "ok",
          "apiBasePath": "/api/v1",
          "nativeClientMinimumRevision": "0.1.48",
          "capabilities": ["arkham.campaign-catalog.v1"],
          "campaignCatalog": {
            "endpoint": "/wrong",
            "catalogRevision": "not-a-revision",
            "schemaVersion": "1.0.0",
            "digestAlgorithm": "sha256"
          }
        }
        """.utf8)
        let capabilities = try ContractJSON.decode(ServerCapabilities.self, from: data)
        let compatibility = ServerCompatibility.modern(
            capabilities: capabilities.capabilities,
            campaignCatalog: capabilities.campaignCatalog
        )
        #expect(capabilities.capabilities.contains(CampaignCatalogAdvertisement.capabilityIdentifier)) // swiftlint:disable:this line_length
        #expect(capabilities.campaignCatalog == nil)
        #expect(!compatibility.advertisesCampaignCatalog)
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

    private func loadLiveCatalog() throws -> CampaignCatalogDocument {
        try ContractJSON.decode(CampaignCatalogDocument.self, from: liveCatalogBytes())
    }

    private func vendoredCatalogBytes() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "campaign-catalog", withExtension: "json", subdirectory: "Fixtures/Contract" // swiftlint:disable:this line_length
        ))
        return try Data(contentsOf: url)
    }

    private func liveCatalogBytes() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "campaign-catalog-25a3eb8",
            withExtension: "json",
            subdirectory: "Fixtures/CampaignCatalogLive"
        ))
        return try Data(contentsOf: url)
    }

    private func catalogBytes(revision: String) throws -> Data {
        var json = try jsonObject(from: vendoredCatalogBytes())
        json["catalogRevision"] = revision
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private func advertisement(revision: String) -> CampaignCatalogAdvertisement {
        CampaignCatalogAdvertisement(
            endpoint: "/api/v1/arkham/campaign-catalog",
            catalogRevision: revision,
            schemaVersion: "1.0.0",
            digestAlgorithm: "sha256"
        )
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

    private func localizedStringKeys(locale: String) throws -> Set<String> {
        let text = try localizedStringsFile(locale: locale)
        let pattern = #"^\"([^\"]+)\"\s*="#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let nsrange = NSRange(text.startIndex ..< text.endIndex, in: text)
        let keys = regex.matches(in: text, range: nsrange).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        return Set(keys)
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
