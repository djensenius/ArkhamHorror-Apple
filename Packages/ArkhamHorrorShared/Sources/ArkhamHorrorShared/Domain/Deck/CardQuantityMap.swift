/// A card-quantity map with normalized (`CardCode`-validated) keys, used by the saved
/// ``DeckList``'s `slots`/`sideSlots`.
struct CardQuantityMap: Sendable {
    let quantities: [CardCode: Int]

    init(_ quantities: [CardCode: Int]) {
        self.quantities = quantities
    }
}

extension CardQuantityMap: Equatable, Hashable {}

extension CardQuantityMap: Codable {
    init(from decoder: any Decoder) throws {
        let raw = try [String: Int](from: decoder)
        var quantities: [CardCode: Int] = [:]
        for (key, value) in raw {
            let code: CardCode
            do {
                code = try CardCode(key)
            } catch {
                let context = DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid card-code key '\(key)' in card quantity map: "
                        + "\(error)"
                )
                throw DecodingError.dataCorrupted(context)
            }
            quantities[code] = value
        }
        self.init(quantities)
    }

    func encode(to encoder: any Encoder) throws {
        var raw: [String: Int] = [:]
        for (code, value) in quantities {
            raw[code.rawValue] = value
        }
        try raw.encode(to: encoder)
    }
}

/// A card-quantity map with permissive (nonempty opaque string) keys, as submitted by
/// external deck sources before backend normalization. Used by ``DeckListInput/slots`` and,
/// when well-formed, ``DeckSideSlotsInput``.
struct CardQuantityMapInput: Sendable {
    let quantities: [String: Int]

    init(_ quantities: [String: Int]) {
        self.quantities = quantities
    }
}

extension CardQuantityMapInput: Equatable, Hashable {}

extension CardQuantityMapInput: Codable {
    init(from decoder: any Decoder) throws {
        let raw = try [String: Int](from: decoder)
        for key in raw.keys where key.isEmpty {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Card quantity map keys must be nonempty"
            )
            throw DecodingError.dataCorrupted(context)
        }
        self.init(raw)
    }

    func encode(to encoder: any Encoder) throws {
        try quantities.encode(to: encoder)
    }
}
