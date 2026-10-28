/// Imports a deck through the linked account rather than the public-URL import path.
struct ArkhamDBImportRequest: Sendable, Equatable {
    let deckId: String

    enum ValidationError: Error { case invalidDeckID }

    init(deckId: String) throws {
        guard !deckId.isEmpty, deckId.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
            throw ValidationError.invalidDeckID
        }
        self.deckId = deckId
    }
}

extension ArkhamDBImportRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case deckId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(deckId: container.decode(String.self, forKey: .deckId))
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .deckId,
                in: container,
                debugDescription: "ArkhamDB deckId must match ^[0-9]+$"
            )
        }
    }
}
