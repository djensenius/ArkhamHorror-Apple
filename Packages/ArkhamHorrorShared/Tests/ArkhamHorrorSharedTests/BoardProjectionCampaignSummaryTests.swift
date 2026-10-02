@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("BoardProjection — campaign summary")
// swiftlint:disable:next type_body_length
struct BoardProjectionCampaignSummaryTests {
    private enum SummaryLocale: Sendable {
        case english
        case german

        var identifier: String {
            switch self {
            case .english: "en"
            case .german: "de"
            }
        }

        var burnedHouse: String {
            switch self {
            case .english: "Your house has burned to the ground"
            case .german: "Dein Haus ist bis auf die Grundmauern niedergebrannt"
            }
        }

        var cultistsWhoGotAway: String {
            switch self {
            case .english: "Cultists who got away"
            case .german: "Kultisten, die entkommen sind"
            }
        }

        var scenarioTitle: String {
            switch self {
            case .english: "The Gathering"
            case .german: "Die Zusammenkunft"
            }
        }

        var maskedHunter: String {
            switch self {
            case .english: "The Masked Hunter"
            case .german: "Der maskierte Jäger"
            }
        }

        var resolutionTitle: String {
            switch self {
            case .english: "Resolution 2"
            case .german: "Auflösung 2"
            }
        }

        var trueTitle: String {
            switch self {
            case .english: "True"
            case .german: "Wahr"
            }
        }

        var falseTitle: String {
            switch self {
            case .english: "False"
            case .german: "Falsch"
            }
        }
    }

    private let investigatorID = BoardTestFixtures.investigatorID("c01001")

    @Test("Campaign handoff summary keeps raw server values and resolves catalogs at display time")
    func campaignHandoffSummaryResolvesCatalogsAfterProjectionBuild() throws {
        let projection = try BoardProjectionBuilder.makeProjection(
            from: fixtureBackedCampaignSnapshot()
        )
        let summary = try #require(projection.campaignSummary)

        assertCampaignHandoffFallback(summary)
        try assertCampaignHandoffSummary(summary, locale: .english)
        try assertCampaignHandoffSummary(summary, locale: .german)
    }

    @Test("Campaign summary chrome reads real en and de Localizable bundles")
    func campaignSummaryChromeUsesRealBundles() {
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("en") {
            #expect(BoardCampaignSummaryLocalization.system.localized(
                "campaign.summary.resolutionNumber", "fallback %d"
            ) == "Resolution %d")
            #expect(BoardCampaignSummaryLocalization.system.localized(
                "campaign.summary.boolean.true", "fallback"
            ) == "True")
        }
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("de") {
            #expect(BoardCampaignSummaryLocalization.system.localized(
                "campaign.summary.resolutionNumber", "fallback %d"
            ) == "Auflösung %d")
            #expect(BoardCampaignSummaryLocalization.system.localized(
                "campaign.summary.boolean.true", "fallback"
            ) == "Wahr")
        }
    }

    @Test("Campaign log key paths strip only a trailing Key suffix")
    func scarletKeysLogKeyUsesCatalogPath() {
        let resolver = LocaleCatalogResolver(snapshot: localeCatalog(
            locale: .english,
            entries: ["theScarletKeys.key.time": "Translated time"]
        ))
        let context = BoardCampaignSummaryDisplayContext(localeCatalogResolver: resolver)
        let scarletKeysTime: JSONValue = .object([
            "tag": .string("TheScarletKeysKey"),
            "contents": .string("Time"),
        ])

        #expect(BoardCampaignSummaryFormatting.logKeyTitle(
            scarletKeysTime, context: context
        ) == "Translated time")
    }

    private func assertCampaignHandoffFallback(_ summary: BoardCampaignSummary) {
        #expect(summary.latestResolution?.title() == "Resolution 2")
        #expect(summary.latestResolution?.detail() == "c01104")
        #expect(summary.log.entries.map { $0.title() } == [
            "Your house has burned to the ground",
            "Custom homebrew thing",
        ])
        #expect(summary.log.counts.map { $0.title() } == ["Your house has burned to the ground"])
        #expect(summary.log.recordedSets.map { $0.title() } == ["Cultists who got away"])
        let values = summary.log.recordedSets.first?.values ?? []
        #expect(values.map { $0.title() } == ["c01121b", "Elder Thing"])
    }

    private func assertCampaignHandoffSummary(
        _ summary: BoardCampaignSummary,
        locale: SummaryLocale
    ) throws {
        try CampaignPromptLocalization.$localizationIdentifierOverride.withValue(
            locale.identifier
        ) {
            let context = try displayContext(locale: locale)

            #expect(summary.latestResolution?.title(context: context) == locale.resolutionTitle)
            #expect(summary.latestResolution?.detail(context: context) == locale.scenarioTitle)
            #expect(summary.log.entries.map { $0.title(context: context) } == [
                locale.burnedHouse,
                "Custom homebrew thing",
            ])
            #expect(summary.log.entries.map(\.isCrossedOut) == [false, false])
            #expect(summary.log.counts.map { $0.title(context: context) } == [locale.burnedHouse])
            #expect(summary.log.counts.map(\.value) == [2])
            #expect(summary.log.recordedSets.map { $0.title(context: context) } == [
                locale.cultistsWhoGotAway,
            ])
            let values = try #require(summary.log.recordedSets.first?.values)
            #expect(values.map { $0.title(context: context) } == [
                locale.maskedHunter, "Elder Thing",
            ])
            #expect(values.map(\.isCrossedOut) == [false, true])
            #expect(values.map(\.isCircled) == [false, true])
            #expect(summary.investigators.first?.displayName == "Roland Banks")
            #expect(summary.investigators.first?.availableExperience == 5)
            #expect(summary.investigators.first?.physicalTrauma == 1)
            #expect(summary.investigators.first?.mentalTrauma == 2)
            #expect(summary.investigators.first?.killed == true)

            #expect(BoardCampaignSummaryFormatting.jsonDisplayValue(
                .bool(true), context: context
            ) == locale.trueTitle)
            #expect(BoardCampaignSummaryFormatting.jsonDisplayValue(
                .bool(false), context: context
            ) == locale.falseTitle)
        }
    }

    private func fixtureBackedCampaignSnapshot() throws -> PublicGameSnapshot {
        try BoardTestFixtures.snapshot(
            mode: fixtureBackedCampaignMode(),
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    name: CardName(title: "Roland Banks", subtitle: nil),
                    physicalTrauma: 1,
                    mentalTrauma: 2,
                    killed: true,
                    spentXp: 3,
                    experiencePoints: 8
                ),
            ],
            playerOrder: [investigatorID]
        )
    }

    // swiftlint:disable:next function_body_length
    private func fixtureBackedCampaignMode() throws -> GameMode {
        var root = try #require(
            JSONSerialization.jsonObject(with: contractFixtureData(named: "mode-campaign-only"))
                as? [String: Any]
        )
        var campaign = try #require(root["This"] as? [String: Any])
        let burnedHouseKey: [String: Any] = [
            "tag": "NightOfTheZealotKey",
            "contents": "YourHouseHasBurnedToTheGround",
        ]
        let fallbackKey: [String: Any] = [
            "tag": "NightOfTheZealotKey",
            "contents": "CustomHomebrewThing",
        ]
        let crossedOutOnlyKey: [String: Any] = [
            "tag": "NightOfTheZealotKey",
            "contents": "TheInvestigatorsWereForcedToWait",
        ]
        let sectionKey: [String: Any] = [
            "tag": "NightOfTheZealotKey",
            "contents": ["tag": "CampaignNotes", "contents": "HiddenSectionEntry"],
        ]
        let cultistsWhoGotAwayKey: [String: Any] = [
            "tag": "NightOfTheZealotKey",
            "contents": "CultistsWhoGotAway",
        ]
        let discoveredGlyphsKey: [String: Any] = [
            "tag": "TheDrownedCityKey",
            "contents": "DiscoveredGlyphs",
        ]
        campaign["completedSteps"] = [["tag": "ScenarioStep", "contents": "c01104"]]
        campaign["log"] = [
            "crossedOut": [crossedOutOnlyKey],
            "options": [],
            "orderedKeys": [],
            "partners": [:],
            "recorded": [
                burnedHouseKey,
                fallbackKey,
                ["tag": "Teachings1"],
                sectionKey,
            ],
            "recordedCounts": [[burnedHouseKey, 2], [sectionKey, 9]],
            "recordedSets": [
                [cultistsWhoGotAwayKey, [
                    someRecorded(
                        recordType: "RecordableCardCode",
                        tag: "Recorded",
                        contents: "c01121b"
                    ),
                    someRecorded(
                        recordType: "RecordableTrait",
                        tag: "CrossedOut",
                        contents: "ElderThing",
                        circled: true
                    ),
                ]],
                [discoveredGlyphsKey, [
                    someRecorded(
                        recordType: "RecordableCardCode",
                        tag: "Recorded",
                        contents: "c11001"
                    ),
                ]],
            ],
        ]
        campaign["resolutions"] = [
            "c01104": ["tag": "Resolution", "contents": 2],
        ]
        root["This"] = campaign
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return try ContractJSON.decode(GameMode.self, from: data)
    }

    private func someRecorded(
        recordType: String,
        tag: String,
        contents: String,
        circled: Bool = false
    ) -> [String: Any] {
        [
            "recordType": recordType,
            "recordVal": [
                "tag": tag,
                "contents": contents,
                "circled": circled,
            ],
        ]
    }

    private func contractFixtureData(named fileName: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: fileName,
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        return try Data(contentsOf: url)
    }

    private func displayContext(
        locale: SummaryLocale
    ) throws -> BoardCampaignSummaryDisplayContext {
        try BoardCampaignSummaryDisplayContext(
            localeCatalogResolver: LocaleCatalogResolver(snapshot: localeCatalog(locale: locale)),
            cardCatalog: cardCatalog(locale: locale)
        )
    }

    private func cardCatalog(locale: SummaryLocale) throws -> CardCatalogSnapshot {
        try CardCatalogSnapshot(namesByCode: [
            CardCode("c01104"): CardName(title: locale.scenarioTitle, subtitle: nil),
            CardCode("c01121b"): CardName(title: locale.maskedHunter, subtitle: nil),
        ])
    }

    private func localeCatalog(locale: SummaryLocale) -> LocaleCatalogSnapshot {
        localeCatalog(locale: locale, entries: [
            "nightOfTheZealot.key.yourHouseHasBurnedToTheGround": locale.burnedHouse,
            "nightOfTheZealot.key.cultistsWhoGotAway": locale.cultistsWhoGotAway,
        ])
    }

    private func localeCatalog(
        locale: SummaryLocale,
        entries rawEntries: [String: String]
    ) -> LocaleCatalogSnapshot {
        let digest = String(repeating: "a", count: 64)
        let descriptor = LocaleCatalogChunkDescriptor(
            pack: "story",
            path: LocaleCatalogGrammar.chunkPath(forDigest: digest),
            bytes: 1,
            sha256: digest,
            keys: rawEntries.count,
            unsupportedKeys: 0
        )
        let manifest = LocaleCatalogManifest(
            catalogRevision: "1.test",
            defaultLocale: "en",
            locales: [
                LocaleCatalogLocaleRecord(
                    locale: locale.identifier,
                    fallback: locale == .english ? nil : "en",
                    chunks: [descriptor],
                    keys: rawEntries.count,
                    bytes: 1
                ),
            ],
            languageResolution: ["en": "en", "de": "de"],
            totals: LocaleCatalogTotals(
                locales: 1,
                chunks: 1,
                bytes: 1,
                keys: rawEntries.count,
                unsupportedKeys: 0
            )
        )
        let entries = rawEntries.mapValues(message)
        return LocaleCatalogSnapshot(
            identity: LocaleCatalogIdentity(
                endpoint: URL(string: "https://catalog.example.test/locale-catalog/manifest.json")!,
                catalogRevision: "1.test",
                locale: locale.identifier,
                manifestSha256: digest
            ),
            manifest: manifest,
            chunks: [
                LocaleCatalogChunkKey(locale: locale.identifier, pack: "story"): LocaleCatalogChunk(
                    locale: locale.identifier,
                    fallback: locale == .english ? nil : "en",
                    pack: "story",
                    entries: entries
                ),
            ]
        )
    }

    private func message(_ text: String) -> LocaleCatalogEntry {
        .message(nodes: [.text(text)], variables: [])
    }
}
