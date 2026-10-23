extension BoardProjection {
    /// Log arrivals update the log sheet, not the board's focus graph or prompt UI.
    /// Keep full equality elsewhere so live-state observers still receive new log rows.
    var boardInteractionProjection: BoardProjection {
        var board = self
        board.gameLog = []
        return board
    }
}
