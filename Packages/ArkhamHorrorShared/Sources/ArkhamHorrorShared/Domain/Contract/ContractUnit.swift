/// Decodes the exact wire body Yesod's `ToJSON ()` instance sends for a handler whose
/// return type is `Handler ()` -- an empty JSON array (`[]`), never `null` or `{}`.
///
/// `DELETE /arkham/games/:id`, `POST /arkham/games/:id/claim-seat`, and
/// `PUT /arkham/games/:id/decks` all return this shape on success. Decoding through
/// this type (via ``ContractJSON``, never a stock `JSONDecoder`) rather than simply
/// discarding the response body keeps every contract boundary -- including a
/// "no meaningful payload" one -- routed through the same lossless decode path, and
/// fails explicitly (rather than silently accepting any bytes) if a future server
/// build ever changes this shape.
struct ContractUnit: Sendable, Equatable {}

extension ContractUnit: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.unkeyedContainer()
        // `isAtEnd` is already `true` before any element is decoded exactly when the
        // array is empty, so this alone confirms the exact "[]" shape.
        guard container.isAtEnd else {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected an empty JSON array (\"[]\"), the exact shape " +
                    "Yesod's ToJSON () instance sends for a Handler () response"
            )
            throw DecodingError.dataCorrupted(context)
        }
    }
}
