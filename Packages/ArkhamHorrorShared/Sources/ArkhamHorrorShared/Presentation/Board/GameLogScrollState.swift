import Foundation

/// Follow arrivals only while the reader is at the live tail, with the web's 40-point tolerance.
struct GameLogScrollState {
    private(set) var isPinnedToBottom = true

    mutating func readerScrolled(distanceFromBottom: CGFloat) {
        isPinnedToBottom = distanceFromBottom < 40
    }

    func target(for lastRowID: String?) -> String? {
        isPinnedToBottom ? lastRowID : nil
    }
}
