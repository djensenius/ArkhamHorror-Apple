import Foundation

/// One row of `PublicGame.log`, accepting both the legacy flat-string format used by
/// 0.1.48-0.1.52 servers and the structured `LogRow` union introduced in 0.1.53.
///
/// Web references for the 0.1.53 shape and audience behavior:
/// `frontend/src/arkham/types/GameLog.ts:356-380` defines the `LogRow` union, and
/// `frontend/src/arkham/components/GameLog.vue:56-61` filters `OnlyPlayer` rows against
/// the viewing player. Native rendering lives in `GameLogPresentation`.
enum GameLogRow: Sendable, Equatable, Hashable {
    case legacy(text: String, step: Int?)
    case structured(GameLogEntry)

    func isVisible(to playerID: PlayerID?) -> Bool {
        switch self {
        case .legacy:
            true
        case let .structured(entry):
            entry.isVisible(to: playerID)
        }
    }
}

extension GameLogRow {
    static func decodeLossyArray<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> [GameLogRow] {
        var nested = try container.nestedUnkeyedContainer(forKey: key)
        var rows: [GameLogRow] = []
        while !nested.isAtEnd {
            let rawRow = try nested.decode(JSONValue.self)
            if let rowData = try? ContractJSON.encode(rawRow) {
                if let row = try? ContractJSON.decode(GameLogRow.self, from: rowData) {
                    rows.append(row)
                }
            }
        }
        return rows
    }
}

extension GameLogRow: Codable {
    enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    init(from decoder: any Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            self = .legacy(text: legacy, step: nil)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "LogRowLegacy":
            let legacy = try GameLogLegacyContents.decode(from: container, forKey: .contents)
            self = .legacy(text: legacy.text, step: legacy.step)
        case "LogRowStructured":
            self = try .structured(container.decode(GameLogEntry.self, forKey: .contents))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .tag,
                in: container,
                debugDescription: "Unsupported LogRow tag \"\(tag)\""
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .legacy(text, step):
            try container.encode("LogRowLegacy", forKey: .tag)
            var contents = container.nestedUnkeyedContainer(forKey: .contents)
            try contents.encode(text)
            try contents.encode(step)
        case let .structured(entry):
            try container.encode("LogRowStructured", forKey: .tag)
            try container.encode(entry, forKey: .contents)
        }
    }
}

private struct GameLogLegacyContents: Sendable, Equatable, Hashable, Codable {
    let text: String
    let step: Int?

    static func decode(
        from container: KeyedDecodingContainer<GameLogRow.CodingKeys>,
        forKey key: GameLogRow.CodingKeys
    ) throws -> (text: String, step: Int?) {
        if let text = try? container.decode(String.self, forKey: key) {
            return (text, nil)
        }
        var values = try container.nestedUnkeyedContainer(forKey: key)
        let text = try values.decode(String.self)
        let step: Int? = if try values.decodeNil() {
            nil
        } else {
            try values.decode(Int.self)
        }
        guard values.isAtEnd else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: values.codingPath,
                debugDescription: "LogRowLegacy contents must be [text, stepOrNull]"
            ))
        }
        return (text, step)
    }
}

/// Structured game-log entry (`Arkham.Log.Entry`) as emitted inside `LogRowStructured`.
struct GameLogEntry: Sendable, Equatable, Hashable, Codable {
    let seq: Int
    let step: Int?
    let kind: OpenStringEnum<GameLogKindTag>
    let body: [GameLogPart]
    let source: GameLogRef?
    let children: [GameLogEntry]
    let audience: GameLogAudience
    let context: GameLogContext
    let tone: OpenStringEnum<GameLogToneTag>?
    let group: GameLogGroup?

    func isVisible(to playerID: PlayerID?) -> Bool {
        switch audience {
        case .everyone:
            true
        case let .onlyPlayer(rowPlayerID):
            rowPlayerID == playerID
        }
    }
}

enum GameLogKindTag: Sendable {}
enum GameLogToneTag: Sendable {}

enum GameLogAudience: Sendable, Equatable, Hashable, Codable {
    case everyone
    case onlyPlayer(PlayerID)

    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "Everyone":
            self = .everyone
        case "OnlyPlayer":
            self = try .onlyPlayer(container.decode(PlayerID.self, forKey: .contents))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .tag,
                in: container,
                debugDescription: "Unsupported LogAudience tag \"\(tag)\""
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .everyone:
            try container.encode("Everyone", forKey: .tag)
        case let .onlyPlayer(playerID):
            try container.encode("OnlyPlayer", forKey: .tag)
            try container.encode(playerID, forKey: .contents)
        }
    }
}

struct GameLogContext: Sendable, Equatable, Hashable, Codable {
    let round: Int?
    let phase: String?
    let turn: String?
}

struct GameLogGroup: Sendable, Equatable, Hashable, Codable {
    let id: String
    let role: OpenStringEnum<GameLogGroupRoleTag>
}

enum GameLogGroupRoleTag: Sendable {}

struct GameLogRef: Sendable, Equatable, Hashable, Codable {
    let kind: OpenStringEnum<GameLogRefKindTag>
    let name: String
    let cardCode: String?
    let cardID: String?
    let entityID: String?
    let faceDown: Bool

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
        case cardCode
        case cardID = "cardId"
        case entityID = "entityId"
        case faceDown
    }
}

enum GameLogRefKindTag: Sendable {}

enum GameLogPart: Sendable, Equatable, Hashable, Codable {
    case text(String)
    case i18n(key: String, variables: [String: GameLogPart])
    case ref(GameLogRef)
    case number(JSONNumber)
    case delta(JSONNumber)
    case token(String)
    case icon(String)
    case campaignKey(JSONValue)
    case list([GameLogPart])

    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    // swiftlint:disable:next cyclomatic_complexity
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "LogText":
            self = try .text(container.decode(String.self, forKey: .contents))
        case "LogI18n":
            var contents = try container.nestedUnkeyedContainer(forKey: .contents)
            let key = try contents.decode(String.self)
            let variables = try contents.decode([String: GameLogPart].self)
            guard contents.isAtEnd else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: contents.codingPath,
                    debugDescription: "LogI18n contents must be [key, variables]"
                ))
            }
            self = .i18n(key: key, variables: variables)
        case "LogRefPart":
            self = try .ref(container.decode(GameLogRef.self, forKey: .contents))
        case "LogNumber":
            self = try .number(container.decode(JSONNumber.self, forKey: .contents))
        case "LogDelta":
            self = try .delta(container.decode(JSONNumber.self, forKey: .contents))
        case "LogToken":
            self = try .token(container.decode(String.self, forKey: .contents))
        case "LogIcon":
            self = try .icon(container.decode(String.self, forKey: .contents))
        case "LogCampaignKey":
            self = try .campaignKey(container.decode(JSONValue.self, forKey: .contents))
        case "LogList":
            self = try .list(container.decode([GameLogPart].self, forKey: .contents))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .tag,
                in: container,
                debugDescription: "Unsupported LogPart tag \"\(tag)\""
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("LogText", forKey: .tag)
            try container.encode(text, forKey: .contents)
        case let .i18n(key, variables):
            try container.encode("LogI18n", forKey: .tag)
            var contents = container.nestedUnkeyedContainer(forKey: .contents)
            try contents.encode(key)
            try contents.encode(variables)
        case let .ref(ref):
            try container.encode("LogRefPart", forKey: .tag)
            try container.encode(ref, forKey: .contents)
        case let .number(number):
            try container.encode("LogNumber", forKey: .tag)
            try container.encode(number, forKey: .contents)
        case let .delta(number):
            try container.encode("LogDelta", forKey: .tag)
            try container.encode(number, forKey: .contents)
        case let .token(token):
            try container.encode("LogToken", forKey: .tag)
            try container.encode(token, forKey: .contents)
        case let .icon(icon):
            try container.encode("LogIcon", forKey: .tag)
            try container.encode(icon, forKey: .contents)
        case let .campaignKey(key):
            try container.encode("LogCampaignKey", forKey: .tag)
            try container.encode(key, forKey: .contents)
        case let .list(parts):
            try container.encode("LogList", forKey: .tag)
            try container.encode(parts, forKey: .contents)
        }
    }
}
