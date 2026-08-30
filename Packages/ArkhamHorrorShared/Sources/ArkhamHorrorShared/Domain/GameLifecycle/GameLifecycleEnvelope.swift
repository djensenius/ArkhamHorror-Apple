/// A minimal, intentionally shallow decode of the `PublicGame` JSON body returned by
/// `POST /arkham/games`, `GET /arkham/games/:id/join`, and `PUT /arkham/games/:id/join`.
///
/// This client never decodes board state -- locations, in-play investigators, the
/// encounter deck, modifiers, and every other field `PublicGame`'s encoder emits -- as
/// that is explicitly out of scope for this slice (see the separate CORE board decoder
/// work). Only the outer `tag`/`id` discriminator is read, exactly as ``GameState``
/// reads only its own `tag`/`contents` discriminator: every other key is simply never
/// asked for, which ``Decodable`` already permits without touching or even parsing
/// their nested structure eagerly.
///
/// A `"PublicGame"` tag (the only variant every code path this client calls can
/// currently produce -- create, join) carries the new/current game's ``GameID``. Any
/// other tag (for example a future addition, or the currently-unreachable-from-this-
/// client `"FailedToLoadGame"` variant) is preserved as ``unsupported`` rather than
/// guessed at, matching ``GameState/unknown(tag:rawObject:)``'s forward-compatible
/// fallback pattern.
enum GameLifecycleEnvelope: Sendable, Equatable {
    case game(GameID)
    case unsupported
}

extension GameLifecycleEnvelope: Decodable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case id
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        if tag == "PublicGame" {
            self = try .game(container.decode(GameID.self, forKey: .id))
        } else {
            self = .unsupported
        }
    }
}
