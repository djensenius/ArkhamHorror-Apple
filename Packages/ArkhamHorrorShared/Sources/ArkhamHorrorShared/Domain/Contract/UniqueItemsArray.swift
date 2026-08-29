/// The error thrown when a ``UniqueItemsArray`` would contain a duplicate element.
enum UniqueItemsArrayError: Error, Equatable, Sendable {
    case duplicateElement
}

/// An array decoded through a JSON array (preserving order, unlike `Set`), that rejects a
/// duplicate element rather than silently collapsing it — matching a schema's
/// `uniqueItems: true` constraint (for example `CardDef.classSymbols`/`cardTraits`).
///
/// A plain `Set<Element>` would decode duplicate-bearing input without complaint (silently
/// discarding the duplicate) and would not preserve the wire's element order on re-encode.
struct UniqueItemsArray<Element: Hashable & Sendable>: Sendable {
    let elements: [Element]

    init(_ elements: [Element]) throws {
        var seen = Set<Element>()
        for element in elements {
            guard seen.insert(element).inserted else {
                throw UniqueItemsArrayError.duplicateElement
            }
        }
        self.elements = elements
    }
}

extension UniqueItemsArray: Equatable, Hashable {}

extension UniqueItemsArray: Sequence {
    func makeIterator() -> IndexingIterator<[Element]> {
        elements.makeIterator()
    }
}

extension UniqueItemsArray: Collection {
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

    func index(after position: Int) -> Int {
        elements.index(after: position)
    }
}

extension UniqueItemsArray: Decodable where Element: Decodable {
    init(from decoder: any Decoder) throws {
        let decoded = try [Element](from: decoder)
        do {
            try self.init(decoded)
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected unique elements, found a duplicate"
                )
            )
        }
    }
}

extension UniqueItemsArray: Encodable where Element: Encodable {
    func encode(to encoder: any Encoder) throws {
        try elements.encode(to: encoder)
    }
}
