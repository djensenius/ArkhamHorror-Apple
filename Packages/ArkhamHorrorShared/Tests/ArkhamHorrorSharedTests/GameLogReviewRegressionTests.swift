@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Game log review regressions")
struct GameLogReviewRegressionTests {
    @Test("Leaf Notice annotations stay visible without a caret after a newer entry arrives")
    func annotationsNeverFold() throws {
        let annotated = entry(1, children: [entry(2, kind: "Notice")])
        let items = GameLogPresentation.items(rows: [
            .structured(annotated), .structured(entry(3, children: [entry(4)])),
        ], playerID: nil)
        let id = try #require(items.first?.id)
        let rows = GameLogOutline.rows(items: items, overrides: [id: false])
        #expect(rows.map(\.entry.seq) == [1, 2, 3, 4])
        #expect(rows.first?.canExpand == false)
        #expect(rows.first?.isExpanded == true)
    }

    @Test("Groups without headers keep their summary below the members, open or folded")
    func headerlessGroupOrdering() throws {
        let url = try #require(Bundle.module.url(
            forResource: "skids-skill-test-rows", withExtension: "json",
            subdirectory: "Fixtures/LiveGameLog"
        ))
        let captured = try ContractJSON.decode([GameLogRow].self, from: Data(contentsOf: url))
        let items = GameLogPresentation.items(rows: [captured[1], captured[4]], playerID: nil)
        let id = try #require(items.first?.id)
        let rows = GameLogOutline.rows(items: items)
        #expect(rows.map(\.entry.seq) == [347, 350])
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.last?.expansionID == id)
        #expect(GameLogOutline.rows(items: items, overrides: [id: false]).map(\.entry.seq) == [350])
    }

    @Test("Backend suffixed bless, curse, frost, and blood faces use their specific token art")
    func suffixedTokenFaces() {
        let renderer = GameLogPartRenderer(resolver: nil)
        for (wire, face) in [
            ("BlessToken", ChaosTokenArtFace.bless), ("CurseToken", .curse),
            ("FrostToken", .frost), ("BloodToken", .blood),
        ] {
            #expect(renderer.render(.token(wire)) == [.semanticIcon(.chaosToken(face))])
            #expect(LegacyGameLogParser.parse("{token:\"\(wire)\"}") == [.token(wire)])
        }
    }

    @Test("Legacy location IDs use lowercase wire UUIDs and duplicate projections are safe")
    func lowercaseLocationLookup() throws {
        let id = try LocationID(#require(UUID(uuidString: "aabbccdd-0000-0000-0000-000000000001")))
        let snapshot = BoardTestFixtures.snapshot(locations: [
            (id, .ordinary(BoardTestFixtures.ordinaryLocation(
                id: id, cardCode: BoardTestFixtures.cardCode("c01112"), revealed: false
            ))),
        ])
        let locations = BoardProjectionBuilder.makeProjection(from: snapshot).locations
        let lookup = GameLogPresentation.legacyLocations(in: locations)
        let parts = LegacyGameLogParser.parse(
            #"{location:"Hall":"aabbccdd-0000-0000-0000-000000000001":"old"}"#,
            locations: lookup
        )
        let reference = try #require(parts.compactMap { part -> GameLogRef? in
            guard case let .ref(ref) = part else { return nil }
            return ref
        }.first)
        #expect(reference.cardCode == "c01112")
        try #require(reference.faceDown)
        #expect(GameLogPresentation.legacyLocations(in: locations + locations).count == 1)
    }

    @Test("Expansion choices stay with sequence IDs when the newest forty-row window slides")
    func slidingWindowIdentities() throws {
        let entries = (1 ... 41).map { seq in
            GameLogRow.structured(entry(seq, children: [entry(100 + seq)]))
        }
        let before = GameLogPresentation.items(rows: Array(entries.prefix(40)), playerID: nil)
        let after = GameLogPresentation.items(rows: Array(entries.suffix(40)), playerID: nil)
        let pinnedID = try #require(before.first { $0.members.first?.seq == 20 }?.id)
        let rows = GameLogOutline.rows(items: after, overrides: [pinnedID: true])
        #expect(rows.contains { $0.entry.seq == 120 })
        #expect(!rows.contains { $0.entry.seq == 121 })
        #expect(rows.first { $0.entry.seq == 20 }?.id == pinnedID)
        #expect(rows.first { $0.entry.seq == 20 }?.isPinned == true)
        #expect(rows.first { $0.entry.seq == 21 }?.isPinned == false)
    }

    @Test("Standalone Tests render their details above a separate sentence and arithmetic band")
    func standaloneTestBand() throws {
        let test = entry(
            1, kind: "Test", children: [entry(2)], body: [.text("Success"), .text("5 − 3 = 2")]
        )
        let items = GameLogPresentation.items(rows: [.structured(test)], playerID: nil)
        #expect(GameLogOutline.rows(items: items).map(\.entry.seq) == [2, 1])
        let id = try #require(items.first?.id)
        #expect(GameLogOutline.rows(items: items, overrides: [id: false]).map(\.entry.seq) == [1])
        let renderer = GameLogPartRenderer(resolver: nil)
        #expect(renderer.renderBody(of: test) == [.text("Success"), .lineBreak, .text("5 − 3 = 2")])
        #expect(renderer.renderBody(of: test, depth: 1) == renderer.render(test.body))
    }

    @Test("Folded rows report all hidden descendants, nesting depth, and pin state")
    func hiddenRowsAndAccessibility() throws {
        let items = GameLogPresentation.items(rows: [
            .structured(entry(1, children: [entry(2, children: [entry(3)]), entry(4)])),
        ], playerID: nil)
        let id = try #require(items.first?.id)
        let row = try #require(GameLogOutline.rows(items: items, overrides: [id: false]).first)
        #expect(row.hiddenRowCount == 3)
        #expect(row.isPinned)
        #expect(row.autoExpanded)
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("en") {
            #expect(GameLogLocalization.accessibilityValue(for: row) ==
                "Collapsed, Level 1, 3 hidden entries, Pinned")
        }
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("de") {
            #expect(GameLogLocalization.accessibilityValue(for: row) ==
                "Eingeklappt, Ebene 1, 3 ausgeblendete Einträge, Angeheftet")
        }
        let defaults = GameLogOutline.rows(items: items, overrides: [id: true])
        let defaultRow = try #require(defaults.first)
        #expect(!defaultRow.isPinned)
        #expect(defaultRow.hiddenRowCount == 0)
    }

    @Test("Captured pre-0.1.53 legacy braces decode real investigator and card references")
    func capturedLegacyBraces() throws {
        // Existing live campaign capture; read in place, not a synthetic or governed fixture.
        let url = try #require(Bundle.module.url(
            forResource: "campaign-replacement-choose-upgrade-deck", withExtension: "json",
            subdirectory: "Fixtures/CampaignPrompt"
        ))
        let envelope = try ContractJSON.decode(GetGameEnvelope.self, from: Data(contentsOf: url))
        let row = try #require(envelope.game.log.dropFirst().first)
        #expect(row == .legacy(
            // swiftlint:disable:next line_length
            text: #"{investigator:"Roland Banks: The Fed":"01001"} played {card:"Research Librarian":"01032":"ab0beabe-80e7-4a7b-9b99-16bf467dbd67"}"#,
            step: nil
        ))
        let items = GameLogPresentation.items(rows: [row], playerID: nil)
        let body = try #require(items.first?.members.first?.body)
        #expect(body == [
            .ref(GameLogRef(
                kind: OpenStringEnum("RefInvestigator"), name: "Roland Banks: The Fed",
                cardCode: "01001", cardID: nil, entityID: "01001", faceDown: false
            )),
            .text(" played "),
            .ref(GameLogRef(
                kind: OpenStringEnum("RefCard"), name: "Research Librarian", cardCode: "01032",
                cardID: "ab0beabe-80e7-4a7b-9b99-16bf467dbd67", entityID: nil, faceDown: false
            )),
        ])
    }

    @Test("Zero-sequence nested siblings have independent index-path IDs and expansion choices")
    func zeroSequenceSiblingIdentities() throws {
        let parent = entry(42, children: [
            entry(0, children: [entry(0)], body: [.text("first cost")]),
            entry(0, children: [entry(0)], body: [.text("second cost")]),
        ])
        let items = GameLogPresentation.items(rows: [.structured(parent)], playerID: nil)
        let rows = GameLogOutline.rows(items: items)
        #expect(rows.map(\.id) == [
            "entry:42", "entry:42.0", "entry:42.0.0", "entry:42.1", "entry:42.1.0",
        ])
        #expect(Set(rows.map(\.id)).count == rows.count)
        let first = try #require(rows.first { $0.entry.body == [.text("first cost")] })
        let second = try #require(rows.first { $0.entry.body == [.text("second cost")] })
        let toggled = GameLogOutline.rows(items: items, overrides: [first.expansionID: false])
        #expect(toggled.first { $0.id == first.id }?.isExpanded == false)
        #expect(toggled.first { $0.id == second.id }?.isExpanded == true)
        #expect(!toggled.contains { $0.id == "entry:42.0.0" })
        #expect(toggled.contains { $0.id == "entry:42.1.0" })
    }

    @Test("Duplicate top-level sequence values are suffixed without changing valid sequence keys")
    func duplicateTopLevelSequenceIdentities() {
        let items = GameLogPresentation.items(rows: [
            .structured(entry(8)), .structured(entry(8)), .structured(entry(9)),
            .structured(entry(8)),
            .structured(entry(10, group: .init(id: "test", role: OpenStringEnum("GroupHeader")))),
            .structured(entry(11, group: .init(id: "test", role: OpenStringEnum("GroupMember")))),
            .structured(entry(11, group: .init(id: "test", role: OpenStringEnum("GroupMember")))),
            .structured(entry(12, group: .init(id: "test", role: OpenStringEnum("GroupMember")))),
        ], playerID: nil)
        let rows = GameLogOutline.rows(items: items)
        #expect(rows.map(\.id) == [
            "entry:8", "entry:8#2", "entry:9", "entry:8#3", "group:test",
            "group:test.entry:11", "group:test.entry:11#2", "group:test.entry:12",
        ])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test("Arrivals preserve scrollback until the reader returns to the bottom")
    func arrivalsRespectScrollback() {
        var state = GameLogScrollState()
        #expect(state.target(for: "entry:1") == "entry:1")
        state.readerScrolled(distanceFromBottom: 120)
        #expect(!state.isPinnedToBottom)
        #expect(state.target(for: "entry:2") == nil)
        #expect(state.target(for: "entry:3") == nil)
        state.readerScrolled(distanceFromBottom: 40)
        #expect(state.target(for: "entry:4") == nil)
        state.readerScrolled(distanceFromBottom: 39)
        #expect(state.isPinnedToBottom)
        #expect(state.target(for: "entry:5") == "entry:5")
        #expect(state.target(for: nil) == nil)
    }

    @Test("Captured group members scroll a pinned reader even when the summary ID is unchanged")
    func capturedGroupArrivalsScrollToUnchangedSummary() throws {
        let url = try #require(Bundle.module.url(
            forResource: "skids-skill-test-rows", withExtension: "json",
            subdirectory: "Fixtures/LiveGameLog"
        ))
        let captured = try ContractJSON.decode([GameLogRow].self, from: Data(contentsOf: url))
        let before = GameLogOutline.rows(items: GameLogPresentation.items(
            rows: Array(captured.prefix(5)), playerID: nil
        ))
        let after = GameLogOutline.rows(items: GameLogPresentation.items(
            rows: Array(captured.prefix(8)), playerID: nil
        ))
        #expect(before.map(\.entry.seq) == [346, 347, 348, 349, 350])
        #expect(after.map(\.entry.seq) == [346, 347, 348, 349, 351, 352, 353, 350])
        let summaryID = try #require(before.last?.id)
        #expect(after.last?.id == summaryID)

        var pinned = GameLogScrollState()
        #expect(pinned.renderedRowsChanged(before.map(\.id)) == summaryID)
        #expect(pinned.renderedRowsChanged(after.map(\.id)) == summaryID)
        #expect(pinned.renderedRowsChanged(after.map(\.id)) == nil)

        var readingHistory = GameLogScrollState()
        #expect(readingHistory.renderedRowsChanged(before.map(\.id)) == summaryID)
        readingHistory.readerScrolled(distanceFromBottom: 120)
        #expect(readingHistory.renderedRowsChanged(after.map(\.id)) == nil)
        #expect(!readingHistory.isPinnedToBottom)
        readingHistory.readerScrolled(distanceFromBottom: 0)
        let next = GameLogOutline.rows(items: GameLogPresentation.items(rows: captured, playerID: nil))
        #expect(readingHistory.renderedRowsChanged(next.map(\.id)) == "entry:354")
    }

    @Test("Depth-zero Test group headers never split off their last body part")
    func groupHeaderDoesNotSplit() {
        let header = entry(
            346, kind: "Test", body: [.text("Test "), .text("against 3")],
            group: .init(id: "test", role: OpenStringEnum("GroupHeader"))
        )
        let renderer = GameLogPartRenderer(resolver: nil)
        #expect(renderer.renderBody(of: header, depth: 0) == [.text("Test "), .text("against 3")])
    }

    private func entry(
        _ seq: Int, kind: String = "Mechanic", children: [GameLogEntry] = [],
        body: [GameLogPart]? = nil, group: GameLogGroup? = nil
    ) -> GameLogEntry {
        GameLogEntry(
            seq: seq, step: nil, kind: OpenStringEnum(kind), body: body ?? [.text("\(seq)")],
            source: nil, children: children, audience: .everyone,
            context: .init(round: nil, phase: nil, turn: nil), tone: nil, group: group
        )
    }
}
