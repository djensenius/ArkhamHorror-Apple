/// One entry of `Investigator.playProhibitions`/`.commitProhibitions` (schema 0.1.57): a
/// card the investigator is currently prohibited from playing or committing, encoded on
/// the wire as a 2-element `[CardId, LogRef[]]` array. `sources` names what imposes the
/// prohibition and may be empty when the backend cannot name it.
struct CardProhibition: Sendable {
    let cardID: WireCardID
    let sources: [GameLogRef]
}

extension CardProhibition: Equatable, Hashable {}

extension CardProhibition: Codable {
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        cardID = try container.decode(WireCardID.self)
        sources = try container.decode([GameLogRef].self)
        guard container.isAtEnd else {
            let context = DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Expected exactly 2 elements for a card prohibition"
            )
            throw DecodingError.dataCorrupted(context)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(cardID)
        try container.encode(sources)
    }
}
