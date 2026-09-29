/// Display-only rendering of a backend calculation/GameValue that may be static or may
/// depend on game state this client does not evaluate.
struct BoardCalculationSummary: Sendable, Equatable, Hashable {
    let displayValue: String
    let staticValue: Int?
}
