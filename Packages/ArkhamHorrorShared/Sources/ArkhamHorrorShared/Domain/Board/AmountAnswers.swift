import Foundation

struct AmountsAnswer: Sendable, Equatable, Encodable {
    let amounts: [String: Int]
    let playerID: PlayerID
    let questionVersion: Int

    func encode(to encoder: any Encoder) throws {
        try AmountAllocationAnswerEnvelope(
            tag: "AmountsAnswer",
            amounts: amounts,
            playerID: playerID,
            questionVersion: questionVersion
        ).encode(to: encoder)
    }
}

struct PaymentAmountsAnswer: Sendable, Equatable, Encodable {
    let amounts: [String: Int]
    let playerID: PlayerID
    let questionVersion: Int

    func encode(to encoder: any Encoder) throws {
        try AmountAllocationAnswerEnvelope(
            tag: "PaymentAmountsAnswer",
            amounts: amounts,
            playerID: playerID,
            questionVersion: questionVersion
        ).encode(to: encoder)
    }
}

struct ExchangeAmountsAnswer: Sendable, Equatable, Encodable {
    let source: JSONValue
    let fromInvestigator: String
    let toInvestigator: String
    let token: String
    let amount: Int

    private enum CodingKeys: String, CodingKey {
        case tag
        case source
        case fromInvestigator
        case toInvestigator
        case token
        case amount
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("ExchangeAmountsAnswer", forKey: .tag)
        try container.encode(source, forKey: .source)
        try container.encode(fromInvestigator, forKey: .fromInvestigator)
        try container.encode(toInvestigator, forKey: .toInvestigator)
        try container.encode(token, forKey: .token)
        try container.encode(amount, forKey: .amount)
    }
}

private struct AmountAllocationAnswerEnvelope: Sendable, Equatable, Encodable {
    let tag: String
    let amounts: [String: Int]
    let playerID: PlayerID
    let questionVersion: Int

    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    private enum ContentsKeys: String, CodingKey {
        case amounts
        case playerID = "playerId"
        case questionVersion
    }

    func encode(to encoder: any Encoder) throws {
        guard questionVersion >= 0 else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "questionVersion must be non-negative"
                )
            )
        }
        var root = encoder.container(keyedBy: CodingKeys.self)
        try root.encode(tag, forKey: .tag)
        var contents = root.nestedContainer(keyedBy: ContentsKeys.self, forKey: .contents)
        try contents.encode(amounts, forKey: .amounts)
        try contents.encode(playerID, forKey: .playerID)
        try contents.encode(questionVersion, forKey: .questionVersion)
    }
}
