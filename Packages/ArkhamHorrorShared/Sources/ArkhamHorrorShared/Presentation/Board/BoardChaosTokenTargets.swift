/// One visible physical chaos token target. The id and face are copied directly from the
/// server token instance so prompt answers can stay tied to authoritative source indices
/// while the board renders an honest target affordance.
struct BoardChaosTokenNode: Sendable, Equatable, Identifiable {
    let id: ChaosTokenID
    let face: ChaosTokenFace
    let cancelled: Bool
    let sealed: Bool

    var displayTitle: String {
        BoardDisplayFormatting.humanizeTag(face.rawValue)
    }
}

extension BoardProjection {
    var targetableChaosTokens: [BoardChaosTokenNode] {
        focusedChaosTokens
    }
}
