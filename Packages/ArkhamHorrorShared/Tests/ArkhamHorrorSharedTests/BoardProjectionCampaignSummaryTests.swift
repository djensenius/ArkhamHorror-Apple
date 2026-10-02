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

        var localization: BoardCampaignSummaryLocalization {
            BoardCampaignSummaryLocalization { key, fallback in
                switch (self, key) {
                case (.english, "campaign.summary.boolean.false"): "False"
                case (.english, "campaign.summary.boolean.true"): "True"
                case (.english, "campaign.summary.noResolution"): "No resolution"
                case (.english, "campaign.summary.resolutionNumber"): "Resolution %d"
                case (.english, "campaign.summary.resolvedStory"): "Resolved story"
                case (.german, "campaign.summary.boolean.false"): "Falsch"
                case (.german, "campaign.summary.boolean.true"): "Wahr"
                case (.german, "campaign.summary.noResolution"): "Keine Auflösung"
                case (.german, "campaign.summary.resolutionNumber"): "Auflösung %d"
                case (.german, "campaign.summary.resolvedStory"): "Abgehandelte Geschichte"
                default: fallback
                }
            }
        }
    }

    private let investigatorID = BoardTestFixtures.investigatorID("c01001")

    @Test("Campaign handoff summary uses catalog text, card titles, and server snapshot bytes")
    func campaignHandoffSummaryUsesCatalogsAndServerValues() throws {
        try assertCampaignHandoffSummary(locale: .english)
        try assertCampaignHandoffSummary(locale: .german)
    }

    private func assertCampaignHandoffSummary(locale: SummaryLocale) throws {
        let context = try displayContext(locale: locale)
        let projection = try BoardProjectionBuilder.makeProjection(
            from: fixtureBackedCampaignSnapshot(),
            localeCatalogResolver: context.localeCatalogResolver,
            cardCatalog: context.cardCatalog,
            campaignSummaryLocalization: context.localization
        )
        let summary = try #require(projection.campaignSummary)

        #expect(summary.latestResolution?.title == locale.resolutionTitle)
        #expect(summary.latestResolution?.detail == locale.scenarioTitle)
        #expect(summary.log.entries.map(\.title) == [
            locale.burnedHouse,
            "Custom homebrew thing",
        ])
        #expect(summary.log.entries.map(\.isCrossedOut) == [false, false])
        #expect(summary.log.counts.map(\.title) == [locale.burnedHouse])
        #expect(summary.log.counts.map(\.value) == [2])
        #expect(summary.log.recordedSets.map(\.title) == [locale.cultistsWhoGotAway])
        let values = try #require(summary.log.recordedSets.first?.values)
        #expect(values.map(\.title) == [locale.maskedHunter, "Elder Thing"])
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
        campaign["completedSteps"] = [["tag": "ScenarioStep", "contents": "01104"]]
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
            "01104": ["tag": "Resolution", "contents": 2],
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
            cardCatalog: cardCatalog(locale: locale),
            localization: locale.localization
        )
    }

    private func cardCatalog(locale: SummaryLocale) throws -> CardCatalogSnapshot {
        try CardCatalogSnapshot(namesByCode: [
            CardCode("c01104"): CardName(title: locale.scenarioTitle, subtitle: nil),
            CardCode("c01121b"): CardName(title: locale.maskedHunter, subtitle: nil),
        ])
    }

    // swiftlint:disable:next function_body_length
    private func localeCatalog(locale: SummaryLocale) -> LocaleCatalogSnapshot {
        let digest = String(repeating: "a", count: 64)
        let descriptor = LocaleCatalogChunkDescriptor(
            pack: "story",
            path: LocaleCatalogGrammar.chunkPath(forDigest: digest),
            bytes: 1,
            sha256: digest,
            keys: 2,
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
                    keys: 2,
                    bytes: 1
                ),
            ],
            languageResolution: ["en": "en", "de": "de"],
            totals: LocaleCatalogTotals(
                locales: 1,
                chunks: 1,
                bytes: 1,
                keys: 2,
                unsupportedKeys: 0
            )
        )
        let entries = [
            "nightOfTheZealot.key.yourHouseHasBurnedToTheGround": message(locale.burnedHouse),
            "nightOfTheZealot.key.cultistsWhoGotAway": message(locale.cultistsWhoGotAway),
        ]
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
