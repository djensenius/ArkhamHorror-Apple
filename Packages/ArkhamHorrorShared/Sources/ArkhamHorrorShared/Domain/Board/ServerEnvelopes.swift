import Foundation

/// The REST `GET` response for a single game: participant or spectator view
/// (`contracts/schemas/get-game.schema.json`).
struct GetGameEnvelope: Sendable {
    let playerID: PlayerID?
    let multiplayerMode: MultiplayerVariant
    let game: PublicGameSnapshot
    let eventID: UUID?
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
            UUID.self,
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

/// A WebSocket server-to-client envelope this contract slice recognizes
/// (`contracts/schemas/server-message.schema.json`'s `GameUpdate` variant). Every other
/// `ServerMessage` tag (`GameMessage`, `GameError`, `GameCard`, ...) belongs to a later
/// contract slice; this type only ever discriminates far enough to either decode a
/// `GameUpdate`'s `PublicGame` payload into the same ``PublicGameSnapshot`` the REST
/// envelope produces, or report an explicit, typed, non-fatal
/// ``unsupportedMessage(tag:rawContents:)`` for anything else — never a silent no-op.
enum BoardSnapshotUpdate: Sendable {
    case snapshot(PublicGameSnapshot)
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
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        guard tag == "GameUpdate" else {
            let rawContents = try container.decodeIfPresent(JSONValue.self, forKey: .contents)
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
        case let .unsupportedMessage(tag, rawContents):
            try container.encode(tag, forKey: .tag)
            try container.encodeIfPresent(rawContents, forKey: .contents)
        }
    }
}
