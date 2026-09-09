import Foundation

struct BasicChoiceAnswer: Sendable, Equatable {
    let choice: Int
    let playerID: PlayerID
    let questionVersion: Int
}

extension BasicChoiceAnswer: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    private enum ContentsKeys: String, CodingKey {
        case choice
        case playerID = "playerId"
        case questionVersion
    }

    init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case let .object(root) = value,
              Set(root.keys) == ["tag", "contents"],
              root["tag"] == .string("Answer"),
              case let .object(contents)? = root["contents"],
              Set(contents.keys) == ["choice", "playerId", "questionVersion"],
              let choice = Self.nonNegativeInteger(contents["choice"]),
              let questionVersion = Self.nonNegativeInteger(contents["questionVersion"]),
              case let .string(playerText)? = contents["playerId"],
              let playerKey = Identifier<PlayerIDTag>(
                  codingKey: AnyCodingKey(stringValue: playerText)
              )
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid Answer envelope")
            )
        }
        self.choice = choice
        playerID = playerKey
        self.questionVersion = questionVersion
    }

    func encode(to encoder: any Encoder) throws {
        guard choice >= 0, questionVersion >= 0 else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Answer integers must be non-negative"
                )
            )
        }
        var root = encoder.container(keyedBy: CodingKeys.self)
        try root.encode("Answer", forKey: .tag)
        var contents = root.nestedContainer(keyedBy: ContentsKeys.self, forKey: .contents)
        try contents.encode(choice, forKey: .choice)
        try contents.encode(playerID, forKey: .playerID)
        try contents.encode(questionVersion, forKey: .questionVersion)
    }

    private static func nonNegativeInteger(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value,
              number.sign == .plus,
              let raw = number.rawToken,
              raw.allSatisfy(\.isASCIIWholeNumber),
              raw == "0" || raw.first != "0",
              let integer = Int(raw),
              integer >= 0
        else { return nil }
        return integer
    }
}
