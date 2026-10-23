import Foundation

/// Follow arrivals only while the reader is at the live tail, with the web's 40-point tolerance.
struct GameLogScrollState {
    private(set) var isPinnedToBottom = true
    private var presentedItems: [GameLogItem] = []

    mutating func itemsChanged(_ items: [GameLogItem], renderedRowIDs: [String]) -> String? {
        // Expansion overrides change rendered rows, not log data, and must not move the reader.
        guard items != presentedItems else { return nil }
        presentedItems = items
        return target(for: renderedRowIDs.last)
    }

    mutating func readerScrolled(distanceFromBottom: CGFloat) {
        isPinnedToBottom = distanceFromBottom < 40
    }

    func target(for lastRowID: String?) -> String? {
        isPinnedToBottom ? lastRowID : nil
    }
}
