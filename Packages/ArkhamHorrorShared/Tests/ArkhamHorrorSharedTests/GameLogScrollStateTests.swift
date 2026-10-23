@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Game log scroll state")
struct GameLogScrollStateTests {
    @Test(
        "Pinned group expansion changes do not follow the tail, but arrivals still do",
        arguments: [true, false]
    )
    func pinnedGroupExpansionDoesNotFollowTail(isExpanded: Bool) throws {
        let url = try #require(Bundle.module.url(
            forResource: "skids-skill-test-rows", withExtension: "json",
            subdirectory: "Fixtures/LiveGameLog"
        ))
        let captured = try ContractJSON.decode([GameLogRow].self, from: Data(contentsOf: url))
        let items = GameLogPresentation.items(rows: Array(captured.prefix(5)), playerID: nil)
        let groupID = try #require(items.last?.id)
        let before = GameLogOutline.rows(items: items, overrides: [groupID: !isExpanded])
        let toggled = GameLogOutline.rows(items: items, overrides: [groupID: isExpanded])
        #expect(before.map(\.id) != toggled.map(\.id))
        #expect(toggled.map(\.entry.seq) == (isExpanded ? [346, 347, 348, 349, 350] : [346, 350]))
        let summaryID = try #require(toggled.last?.id)
        #expect(summaryID == "group:skillTest:a3d670b6-a22e-4409-96e4-cf48872f2425.summary")

        var state = GameLogScrollState()
        #expect(state.itemsChanged(items, renderedRowIDs: before.map(\.id)) == summaryID)
        #expect(state.itemsChanged(items, renderedRowIDs: toggled.map(\.id)) == nil)
        #expect(state.isPinnedToBottom)

        let afterItems = GameLogPresentation.items(rows: Array(captured.prefix(8)), playerID: nil)
        let after = GameLogOutline.rows(items: afterItems, overrides: [groupID: isExpanded])
        #expect(after.map(\.entry.seq) ==
            (isExpanded ? [346, 347, 348, 349, 351, 352, 353, 350] : [346, 350]))
        #expect(state.itemsChanged(afterItems, renderedRowIDs: after.map(\.id)) == summaryID)
        #expect(state.itemsChanged(afterItems, renderedRowIDs: after.map(\.id)) == nil)
    }
}
