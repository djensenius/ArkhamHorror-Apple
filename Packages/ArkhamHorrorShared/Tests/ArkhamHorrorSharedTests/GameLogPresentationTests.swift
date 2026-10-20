@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Game log presentation")
struct GameLogPresentationTests {
    @Test("Captured skill test keeps header, post-summary members, outcome, and next phase")
    func capturedSkillTest() throws {
        let rows = try capturedRows()
        let items = GameLogPresentation.items(rows: rows, playerID: nil)
        try #require(items.count == 2)
        let group = try #require(items.first)
        #expect(group.header?.seq == 346)
        #expect(group.members.map(\.seq) == [347, 348, 349, 351, 352, 353])
        #expect(group.summary?.seq == 350)
        #expect(group.summary?.tone?.rawValue == "Good")
        #expect(items[1].members.first?.seq == 354)
    }

    @Test("Captured summary arithmetic is separated from the sentence, never concatenated")
    func summaryArithmeticIsSeparated() throws {
        let rows = try capturedRows()
        guard case let .structured(summary) = rows[4] else {
            Issue.record("Expected captured group summary")
            return
        }
        let renderer = GameLogPartRenderer(resolver: nil)
        let body = renderer.renderBody(of: summary)
        let sentence = renderer.render(summary.body[0])
        let statistics = renderer.render(summary.body[1])
        #expect(body == sentence + [.lineBreak] + statistics)
        #expect(body.filter { $0 == .lineBreak }.count == 1)
        guard case let .structured(header) = rows[0] else {
            Issue.record("Expected captured group header")
            return
        }
        #expect(renderer.renderBody(of: header) == renderer.render(header.body))
    }

    @Test("Grouping reunites nonadjacent rows and orphaned members remain readable")
    func nonadjacentAndPartialGroups() throws {
        let rows = try capturedRows()
        let items = GameLogPresentation.items(
            rows: [rows[0], rows[8], rows[1], rows[4]],
            playerID: nil
        )
        try #require(items.count == 2)
        #expect(items[0].members.map(\.seq) == [347])
        #expect(items[0].summary?.seq == 350)
        #expect(items[1].members.map(\.seq) == [354])
        let orphaned = GameLogPresentation.items(rows: [rows[1], rows[2]], playerID: nil)
        #expect(orphaned.map(\.isGroup) == [false, false])
        #expect(orphaned.flatMap(\.members).map(\.seq) == [347, 348])
    }

    @Test("Private entries and private nested children are hidden from other seats and spectators")
    func audiencesAreRecursive() {
        let player = PlayerID(UUID())
        let child = entry(2, audience: .onlyPlayer(player))
        let parent = entry(1, children: [child, entry(3)])
        let rows: [GameLogRow] = [.structured(parent), .structured(child)]
        let spectator = GameLogPresentation.items(rows: rows, playerID: nil)
        #expect(spectator.count == 1)
        #expect(spectator[0].members[0].children.map(\.seq) == [3])
        let other = GameLogPresentation.items(rows: rows, playerID: PlayerID(UUID()))
        #expect(other == spectator)
        let own = GameLogPresentation.items(rows: rows, playerID: player)
        #expect(own.count == 2)
        #expect(own[0].members[0].children.map(\.seq) == [2, 3])
    }

    @Test("Legacy brace arities, escaped names, custom tokens, and unknown fragments match the web")
    func legacyBraceDSL() {
        // swiftlint:disable:next line_length
        let body = #"{card:"A \"quoted\" card":c01093:"copy"} {investigator:"Roland":"c01001"} {enemy:"Ghoul":ignored:"c01116"} {location:"Hall":"loc":"old"} {location:"Study":other} {token:"CustomToken "Skull""} {future:raw}"#
        let parts = LegacyGameLogParser.parse(body, locations: [
            "loc": .init(cardCode: "c01112", revealed: false),
        ])
        let refs = parts.compactMap { part -> GameLogRef? in
            guard case let .ref(value) = part else { return nil }; return value
        }
        #expect(refs.map(\.kind.rawValue) == [
            "RefCard", "RefInvestigator", "RefEnemy", "RefLocation", "RefLocation",
        ])
        #expect(refs[0].name == #"A "quoted" card"#)
        #expect(refs[0].cardID == "copy")
        #expect(refs[1].entityID == "c01001")
        #expect(refs[2].cardCode == "c01116")
        #expect(refs[3].cardCode == "c01112")
        #expect(refs[3].faceDown)
        #expect(refs[4].entityID == "other")
        #expect(parts.contains(.token("Skull")))
        #expect(parts.last == .text("{future:raw}"))
    }

    @Test(
        "Legacy whole i18n parameters stay numeric; embedded keys and literal prose stay distinct"
    )
    func legacyI18nDSL() {
        #expect(LegacyGameLogParser
            .parse(#" $log.gainsResources count=i:2 investigator=s:"A \"quoted\" name" "#) == [
                .i18n(key: "log.gainsResources", variables: [
                    "count": .number(.integer(2)), "investigator": .text(#"A "quoted" name"#),
                ]),
            ])
        #expect(LegacyGameLogParser.parse("Before $log.phase.enemy after") == [
            .text("Before "), .i18n(key: "log.phase.enemy", variables: [:]), .text(" after"),
        ])
        let normalized = GameLogPresentation.items(
            rows: [.legacy(text: "literal", step: 7)],
            playerID: nil
        )
        #expect(normalized.first?.members.first?.step == 7)
        #expect(normalized.first?.members.first?.seq == 0)
    }

    @Test(
        "Runtime plurals preserve nested refs, glyphs, and localized list joins"
    )
    func richCatalogParts() async throws {
        let resolver = try await catalogResolver()
        let renderer = GameLogPartRenderer(resolver: resolver)
        let singular = renderer.render(.i18n(key: "log.clues", variables: [
            "count": .number(.integer(1)), "who": .ref(reference("Roland", code: "c01001")),
        ]))
        #expect(singular == [
            .cardReference(code: "01001", children: [.text("Roland")]),
            .text(" findet "), .text("1"), .text(" Hinweis"),
        ])
        let plural = renderer.render(.i18n(key: "log.clues", variables: [
            "count": .number(.integer(2)), "who": .i18n(key: "log.someone", variables: [:]),
        ]))
        #expect(plural.map(\.plainText).joined() == "Jemand findet 2 Hinweise")
        let list = renderer.render(.list([
            .token("Skull"),
            .icon("intellect"),
            .delta(.integer(-2)),
        ]))
        #expect(list == [
            .semanticIcon(.chaosToken(.skull)), .text(", "), .semanticIcon(.skill(.intellect)),
            .text(" und "), .text("−2"),
        ])
        let slots = renderer.render(.i18n(
            key: "log.slots",
            variables: ["value": .list([.icon("combat")])]
        ))
        #expect(slots == [.semanticIcon(.skill(.combat))])
        #expect(renderer.render(.token("Zero")) == [.text("0")])
        #expect(renderer.render(.delta(.integer(0))) == [.text("+0")])
    }

    @Test("Missing catalogs and keys are explicitly unavailable, never raw keys presented as prose")
    func missingTranslationsAreHonest() async throws {
        let resolver = try await catalogResolver()
        for renderer in [
            GameLogPartRenderer(resolver: nil),
            GameLogPartRenderer(resolver: resolver),
        ] {
            let nodes = renderer.render(.i18n(
                key: "future.missing",
                variables: ["count": .number(.integer(2))]
            ))
            #expect(nodes == [
                .text(GameLogLocalization.unavailable("future.missing")),
                .text(" · count: "),
                .text("2"),
            ])
            #expect(!nodes.map(\.plainText).joined().contains("$future.missing"))
        }
    }

    @Test(
        "Card catalog names win after prefix/side normalization; missing cards retain server names"
    )
    func referenceNamesAndCampaignKeys() async throws {
        let resolver = try await catalogResolver()
        let catalog = try CardCatalogSnapshot(namesByCode: [
            CardCode("c01001"): CardName(title: "Lokaler Name", subtitle: nil),
        ])
        let renderer = GameLogPartRenderer(resolver: resolver, cardCatalog: catalog)
        #expect(renderer.render(.ref(reference("server", code: "c01001a"))) == [
            .cardReference(code: "01001a", children: [.text("Lokaler Name")]),
        ])
        #expect(renderer.render(.ref(reference("Server Name", code: "c99999"))) == [
            .cardReference(code: "99999", children: [.text("Server Name")]),
        ])
        #expect(renderer.render(.campaignKey(.object(["tag": .string("TheHouseStands")]))) == [
            .text("Das Haus steht"),
        ])
        #expect(renderer
            .render(.campaignKey(.object(["tag": .string("UnwrittenHomebrewKey")]))) == [
                .text("Unwritten homebrew key"),
            ])
        #expect(renderer.render(.text("A [tdc_rune_m] {runeA}")) == [
            .text("A "), .icon("rune-M"), .text(" "), .icon("rune-A"),
        ])
        #expect(renderer.render(.icon("futureSymbol")) == [.icon("futureSymbol")])
    }

    @Test("All game-log UI strings ship in the English and German bundles")
    func localizedBundles() {
        for (language, expected) in [
            (
                "en",
                [
                    "Game Log",
                    "No log entries yet.",
                    "Close",
                    "Translation unavailable (%@)",
                    "Expanded",
                    "Collapsed",
                ]
            ),
            (
                "de",
                [
                    "Spielverlauf",
                    "Noch keine Einträge im Spielverlauf.",
                    "Schließen",
                    "Übersetzung nicht verfügbar (%@)",
                    "Ausgeklappt",
                    "Eingeklappt",
                ]
            ),
        ] {
            CampaignPromptLocalization.$localizationIdentifierOverride.withValue(language) {
                #expect([
                    GameLogLocalization.title,
                    GameLogLocalization.empty,
                    GameLogLocalization.close,
                    GameLogLocalization.unavailable("%@"),
                    GameLogLocalization.expanded, GameLogLocalization.collapsed,
                ] == expected)
            }
        }
    }
}

private extension GameLogPresentationTests {
    func capturedRows() throws -> [GameLogRow] {
        let url = try #require(Bundle.module.url(
            forResource: "skids-skill-test-rows", withExtension: "json",
            subdirectory: "Fixtures/LiveGameLog"
        ))
        return try ContractJSON.decode([GameLogRow].self, from: Data(contentsOf: url))
    }

    func entry(
        _ seq: Int, children: [GameLogEntry] = [], audience: GameLogAudience = .everyone
    ) -> GameLogEntry {
        GameLogEntry(
            seq: seq, step: nil, kind: OpenStringEnum("Mechanic"), body: [.text("row \(seq)")],
            source: nil, children: children, audience: audience,
            context: .init(round: nil, phase: nil, turn: nil), tone: nil, group: nil
        )
    }

    func reference(_ name: String, code: String) -> GameLogRef {
        GameLogRef(
            kind: OpenStringEnum("RefCard"), name: name, cardCode: code,
            cardID: nil, entityID: nil, faceDown: false
        )
    }

    func catalogResolver() async throws -> LocaleCatalogResolver {
        // swiftlint:disable line_length
        let rawEntries = #"""
        {"log.clues":{"form":"plural","cases":[
          [{"type":"var","name":"who","role":"text"},{"type":"text","value":" findet "},{"type":"var","name":"count","role":"text"},{"type":"text","value":" Hinweis"}],
          [{"type":"var","name":"who","role":"text"},{"type":"text","value":" findet "},{"type":"var","name":"count","role":"text"},{"type":"text","value":" Hinweise"}]],"variables":[]},
         "log.someone":{"form":"message","nodes":[{"type":"text","value":"Jemand"}],"variables":[]},
         "log.slots":{"form":"message","nodes":[{"type":"var","name":"value","role":"text"}],"variables":[]},
         "log.listSeparator":{"form":"message","nodes":[{"type":"text","value":", "}],"variables":[]},
         "log.listLast":{"form":"message","nodes":[{"type":"text","value":" und "}],"variables":[]},
         "base.key.theHouseStands":{"form":"message","nodes":[{"type":"text","value":"Das Haus steht"}],"variables":[]}}
        """#
        // swiftlint:enable line_length
        let rawData = try #require(rawEntries.data(using: .utf8))
        var entries = try #require(JSONSerialization
            .jsonObject(with: rawData) as? [String: [String: Any]])
        for key in entries.keys {
            var entry = try #require(entries[key])
            var declarations: [String: [String: String]] = [:]
            func declare(_ nodes: [[String: String]]) -> [[String: String]] {
                nodes.map { node in
                    guard node["type"] == "var", let name = node["name"] else { return node }
                    var value = node
                    value["source"] = "named"
                    declarations[name] = ["name": name, "source": "named", "role": "text"]
                    return value
                }
            }
            if let nodes = entry["nodes"] as? [[String: String]] {
                entry["nodes"] = declare(nodes)
            }
            if let cases = entry["cases"] as? [[[String: String]]] {
                entry["cases"] = cases.map(declare)
            }
            entry["variables"] = declarations.keys.sorted().compactMap { declarations[$0] }
            entries[key] = entry
        }
        let encodedEntries = try JSONSerialization.data(withJSONObject: entries)
        let encodedString = try #require(String(data: encodedEntries, encoding: .utf8))
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: [
                "log.clues",
                "log.someone",
                "log.slots",
                "log.listSeparator",
                "log.listLast",
                "base.key.theHouseStands",
            ],
            chunkEntries: encodedString
        )
        return try await LocaleCatalogResolver(snapshot: documents.loadSnapshot())
    }
}
