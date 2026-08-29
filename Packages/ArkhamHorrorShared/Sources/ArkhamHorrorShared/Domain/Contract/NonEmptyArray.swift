/// The error thrown when constructing or decoding a ``NonEmptyArray`` from zero elements.
enum NonEmptyArrayError: Error, Equatable, Sendable {
    case empty
}

/// An array validated to contain at least one element, used where the contract's schema
/// declares `minItems: 1` (for example `deckValidationErrors`). Unlike a plain `[Element]`,
/// an empty JSON array cannot decode as this type — it is rejected rather than silently
/// accepted as a technically-well-typed-but-contract-violating empty result.
struct NonEmptyArray<Element: Sendable>: Sendable {
    let elements: [Element]

    init(_ elements: [Element]) throws {
        guard !elements.isEmpty else {
            throw NonEmptyArrayError.empty
        }
        self.elements = elements
    }
}

extension NonEmptyArray: Equatable where Element: Equatable {}
extension NonEmptyArray: Hashable where Element: Hashable {}

extension NonEmptyArray: Sequence {
    func makeIterator() -> IndexingIterator<[Element]> {
        elements.makeIterator()
    }
}

extension NonEmptyArray: Collection {
    typealias Index = Int

    var startIndex: Int {
        elements.startIndex
    }

    var endIndex: Int {
        elements.endIndex
    }

    subscript(position: Int) -> Element {
        elements[position]
    }

    func index(after index: Int) -> Int {
        elements.index(after: index)
    }
}

extension NonEmptyArray: Decodable where Element: Decodable {
    init(from decoder: any Decoder) throws {
        let decoded = try [Element](from: decoder)
        do {
            try self.init(decoded)
        } catch {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a non-empty array, got an empty array"
            )
            throw DecodingError.dataCorrupted(context)
        }
    }
}

extension NonEmptyArray: Encodable where Element: Encodable {
    func encode(to encoder: any Encoder) throws {
        try elements.encode(to: encoder)
    }
}
