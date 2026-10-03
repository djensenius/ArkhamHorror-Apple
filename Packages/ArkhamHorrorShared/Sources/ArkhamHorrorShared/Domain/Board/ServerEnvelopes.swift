import Foundation

/// The REST `GET` response for a single game: participant or spectator view
/// (`contracts/schemas/get-game.schema.json`).
struct GetGameEnvelope: Sendable {
    let playerID: PlayerID?
    let multiplayerMode: MultiplayerVariant
    let game: PublicGameSnapshot
    let eventID: EventCorrelationID?
}

extension GetGameEnvelope: Equatable, Hashable {}

extension GetGameEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case playerID = "playerId"
        case multiplayerMode
        case game
        case eventID = "eventId"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playerID = try decodeRequiredNullable(
            PlayerID.self,
            from: container,
            forKey: .playerID,
            codingPath: decoder.codingPath + [CodingKeys.playerID]
        )
        multiplayerMode = try container.decode(MultiplayerVariant.self, forKey: .multiplayerMode)
        game = try container.decode(PublicGameSnapshot.self, forKey: .game)
        eventID = try decodeRequiredNullable(
            EventCorrelationID.self,
            from: container,
            forKey: .eventID,
            codingPath: decoder.codingPath + [CodingKeys.eventID]
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(playerID, forKey: .playerID)
        try container.encode(multiplayerMode, forKey: .multiplayerMode)
        try container.encode(game, forKey: .game)
        try container.encode(eventID, forKey: .eventID)
    }
}

/// A server-authored answer rejection sent only to the answering connection.
struct AnswerRejectedMessage: Sendable, Equatable, Hashable {
    let reason: String
    let questionVersion: Int?
}

extension AnswerRejectedMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case reason
        case questionVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = try container.decode(String.self, forKey: .reason)
        questionVersion = try container.decodeIfPresent(Int.self, forKey: .questionVersion)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reason, forKey: .reason)
        try container.encode(questionVersion, forKey: .questionVersion)
    }
}

/// A WebSocket server-to-client envelope this contract slice recognizes
/// (`contracts/schemas/server-message.schema.json`). `GameError` is recognized only as
/// uncorrelated, room-wide feedback: the backend supplies no player/question/request
/// correlation, so it can never establish that this client's answer was rejected.
/// Every other `ServerMessage` tag belongs to a later contract slice; this type only
/// discriminates far enough to decode a `GameUpdate`, `GameError`, or `AnswerRejected`,
/// or report an explicit, typed, non-fatal ``unsupportedMessage(tag:rawContents:)`` for
/// anything else — never a silent no-op.
enum BoardSnapshotUpdate: Sendable {
    case snapshot(PublicGameSnapshot)
    case gameError(rawMessage: String)
    case answerRejected(AnswerRejectedMessage)
    /// A recognized-or-unrecognized `ServerMessage` tag this contract slice does not
    /// decode further. `rawContents` preserves whatever `contents`-shaped payload (if
    /// any) accompanied it, for diagnostics.
    case unsupportedMessage(tag: String, rawContents: JSONValue?)
}

extension BoardSnapshotUpdate: Equatable, Hashable {}

extension BoardSnapshotUpdate: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
        case reason
        case questionVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        if tag == "GameError", let message = try? container.decode(String.self, forKey: .contents) {
            self = .gameError(rawMessage: message)
            return
        }
        if tag == "AnswerRejected" {
            self = try .answerRejected(Self.decodeAnswerRejected(from: container))
            return
        }
        guard tag == "GameUpdate" else {
            // Distinguishes an absent `contents` key (`nil`) from an explicit
            // `"contents": null` (`.some(.null)`): `decodeIfPresent(JSONValue.self, ...)`
            // would collapse both to `nil`, losing exactly the raw-payload diagnostic
            // this case exists to preserve.
            let rawContents = container.contains(.contents)
                ? try container.decode(JSONValue.self, forKey: .contents)
                : nil
            self = .unsupportedMessage(tag: tag, rawContents: rawContents)
            return
        }
        self = try .snapshot(container.decode(PublicGameSnapshot.self, forKey: .contents))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .snapshot(snapshot):
            try container.encode("GameUpdate", forKey: .tag)
            try container.encode(snapshot, forKey: .contents)
        case let .gameError(rawMessage):
            try container.encode("GameError", forKey: .tag)
            try container.encode(rawMessage, forKey: .contents)
        case let .answerRejected(rejection):
            try container.encode("AnswerRejected", forKey: .tag)
            try container.encode(rejection.reason, forKey: .reason)
            try container.encode(rejection.questionVersion, forKey: .questionVersion)
        case let .unsupportedMessage(tag, rawContents):
            try container.encode(tag, forKey: .tag)
            try container.encodeIfPresent(rawContents, forKey: .contents)
        }
    }

    private static func decodeAnswerRejected(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> AnswerRejectedMessage {
        if container.contains(.contents) {
            if let wrapped = try? container.decode(AnswerRejectedMessage.self, forKey: .contents) {
                return wrapped
            }
        }
        let reason = try container.decode(String.self, forKey: .reason)
        let questionVersion = try container.decodeIfPresent(Int.self, forKey: .questionVersion)
        return AnswerRejectedMessage(reason: reason, questionVersion: questionVersion)
    }
}
