@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Game log outline and live projection")
struct GameLogOutlineTests {
    @Test("Board projection retains captured audience-bearing rows for the live log surface")
    func projectionRetainsRows() throws {
        let snapshotURL = try #require(Bundle.module.url(
            forResource: "get-game", withExtension: "json", subdirectory: "Fixtures/Contract"
        ))
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: Data(contentsOf: snapshotURL)
        )
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        #expect(!projection.gameLog.isEmpty)
        #expect(projection.gameLog == envelope.game.log)
    }

    @Test("Newest group opens through chat, then folds when a later event arrives; pins survive")
    func groupLiveTailAndPins() throws {
        let fixture = try #require(Bundle.module.url(
            forResource: "skids-skill-test-rows", withExtension: "json",
            subdirectory: "Fixtures/LiveGameLog"
        ))
        let captured = try ContractJSON.decode([GameLogRow].self, from: Data(contentsOf: fixture))
        let grouped = GameLogPresentation.items(rows: Array(captured.prefix(8)), playerID: nil)
        let open = GameLogOutline.rows(items: grouped)
        #expect(open.map(\.entry.seq) == [346, 347, 348, 349, 351, 352, 353, 350])
        #expect(open.first?.isExpanded == true)
        let chat = GameLogPresentation.items(
            rows: [.structured(entry(500, kind: "Chat"))],
            playerID: nil
        )
        #expect(GameLogOutline.rows(items: grouped + chat).count == 9)
        let withNextEvent = GameLogPresentation.items(rows: captured, playerID: nil)
        let closed = GameLogOutline.rows(items: withNextEvent)
        #expect(closed.map(\.entry.seq) == [346, 350, 354])
        #expect(closed.first?.isExpanded == false)
        let id = try #require(grouped.first?.id)
        let pinned = GameLogOutline.rows(items: withNextEvent, overrides: [id: true])
        #expect(pinned.map(\.entry.seq) == open.map(\.entry.seq) + [354])
        #expect(GameLogOutline.rows(items: grouped, overrides: [id: false])
            .map(\.entry.seq) == [346, 350])
    }

    @Test("Nested entries share the newest spine; explicit closed parents hide all descendants")
    func nestedSpines() throws {
        let first = entry(1, children: [entry(2, children: [entry(3)])])
        let second = entry(4, children: [entry(5)])
        let before = GameLogPresentation.items(rows: [.structured(first)], playerID: nil)
        #expect(GameLogOutline.rows(items: before).map(\.entry.seq) == [1, 2, 3])
        #expect(GameLogOutline.rows(items: before).map(\.depth) == [0, 1, 2])
        let id = try #require(before.first?.id)
        let after = GameLogPresentation.items(
            rows: [.structured(first), .structured(second)],
            playerID: nil
        )
        #expect(GameLogOutline.rows(items: after).map(\.entry.seq) == [1, 4, 5])
        #expect(GameLogOutline.rows(items: before, overrides: [id: false]).map(\.entry.seq) == [1])
        #expect(GameLogOutline.rows(items: after, overrides: [id: true]).map(\.entry.seq) == [
            1,
            2,
            4,
            5,
        ])
    }

    @Test("Log glyph mappings follow web CSS for actions, classes, and all 26 runes")
    func logGlyphMappings() throws {
        let glyphs = StoryIconGlyph.logGlyphs
        #expect(glyphs.count == 34)
        let action = try #require(StoryIconGlyph.byIconName["action"])
        #expect(action.family == .arkham)
        #expect(action.scalar.value == 0x49)
        #expect(StoryIconGlyph.byIconName["fast"]?.scalar.value == 0x75)
        #expect(StoryIconGlyph.byIconName["reaction"]?.scalar.value == 0x79)
        #expect(StoryIconGlyph.byIconName["guardian"]?.scalar.value == 0x51)
        #expect(StoryIconGlyph.byIconName["seeker"]?.scalar.value == 0x45)
        #expect(StoryIconGlyph.byIconName["rogue"]?.scalar.value == 0x54)
        #expect(StoryIconGlyph.byIconName["mystic"]?.scalar.value == 0x57)
        #expect(StoryIconGlyph.byIconName["survivor"]?.scalar.value == 0x52)
        for (offset, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            let rune = try #require(StoryIconGlyph.byIconName["rune-\(letter)"])
            #expect(rune.family == .arkhamSlim)
            #expect(rune.cssClass == "rune-\(letter)")
            #expect(rune.scalar.value == UInt32(0xE900 + offset))
        }
    }

    @Test("Log glyphs use verified PostScript names; absent fonts or scalars never emit PUA text")
    func missingGlyphsUseFallback() throws {
        let glyph = try #require(StoryIconGlyph.byIconName["rune-M"])
        #expect(StoryInlineTextRenderer.namedIconGlyph(
            "rune-M", iconFonts: WebIconFontAvailability()
        ) == nil)
        let missingScalar = WebIconFontAvailability(registrations: [
            .arkhamSlim: .init(
                family: .arkhamSlim,
                postScriptName: "RuntimeSlim",
                supportedScalars: []
            ),
        ])
        #expect(StoryInlineTextRenderer.namedIconGlyph("rune-M", iconFonts: missingScalar) == nil)
        let loaded = WebIconFontAvailability(registrations: [
            .arkhamSlim: .init(
                family: .arkhamSlim, postScriptName: "RuntimeSlim",
                supportedScalars: [glyph.scalar.value]
            ),
        ])
        #expect(StoryInlineTextRenderer.namedIconGlyph("rune-M", iconFonts: loaded) == .webGlyph(
            iconName: "rune-M", fontName: "RuntimeSlim", glyph: "\u{E90C}"
        ))
        #expect(StoryInlineTextRenderer.namedIconGlyph("future-symbol", iconFonts: loaded) == nil)
    }

    private func entry(
        _ seq: Int,
        kind: String = "Mechanic",
        children: [GameLogEntry] = []
    ) -> GameLogEntry {
        GameLogEntry(
            seq: seq, step: nil, kind: OpenStringEnum(kind), body: [.text("\(seq)")],
            source: nil, children: children, audience: .everyone,
            context: .init(round: nil, phase: nil, turn: nil), tone: nil, group: nil
        )
    }
}
