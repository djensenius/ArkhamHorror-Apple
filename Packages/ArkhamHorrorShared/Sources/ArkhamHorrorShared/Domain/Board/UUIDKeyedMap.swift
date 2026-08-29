import Foundation

/// A JSON-object-keyed map whose keys are a UUID-backed ``Identifier``, decoded through a
/// dedicated container rather than the stdlib's generic `Dictionary: Decodable`
/// conformance (driven by `CodingKeyRepresentable`).
///
/// The stdlib path silently *overwrites* on a raw-key collision after normalization
/// (`Dictionary.init(from:)`'s `CodingKeyRepresentable` branch builds its result with a
/// plain, order-dependent `self[key] = value` subscript assignment): two textually
/// distinct raw keys that both happen to parse to the same UUID (for example a stray
/// uppercase-rendered duplicate of an otherwise-lowercase key) would silently collapse to
/// whichever happened to be visited last, rather than failing. This type instead: (1)
/// requires every raw key to already be in the backend's own canonical
/// lowercase-hyphenated `ToJSONKey` form — rejecting any other case-form outright, via
/// ``Identifier``'s own (equally strict) `CodingKeyRepresentable` conformance — and (2)
/// explicitly, separately rejects a second raw key that still normalizes to an
/// already-seen identifier, rather than relying on (1) alone to make that unreachable.
///
/// Used for every UUID-`Identifier`-keyed map in ``PublicGameSnapshot`` — `locations` and
/// every ``UUIDEntityMap`` field (`enemies`, `assets`, `treacheries`, `events`,
/// `concealed`, `skills`, `question`, `cards`) — in place of a bare
/// `[Identifier<Tag>: Value]`, so this validation is enforced uniformly rather than
/// per-field.
struct UUIDKeyedMap<Tag: Sendable, Value: Sendable>: Sendable {
    var entries: [Identifier<Tag>: Value]

    init(_ entries: [Identifier<Tag>: Value] = [:]) {
        self.entries = entries
    }
}

extension UUIDKeyedMap: Equatable where Value: Equatable {}
extension UUIDKeyedMap: Hashable where Value: Hashable {}

extension UUIDKeyedMap: Sequence {
    func makeIterator() -> Dictionary<Identifier<Tag>, Value>.Iterator {
        entries.makeIterator()
    }
}

extension UUIDKeyedMap: Collection {
    typealias Index = Dictionary<Identifier<Tag>, Value>.Index

    var startIndex: Index {
        entries.startIndex
    }

    var endIndex: Index {
        entries.endIndex
    }

    subscript(position: Index) -> (key: Identifier<Tag>, value: Value) {
        entries[position]
    }

    func index(after position: Index) -> Index {
        entries.index(after: position)
    }
}

extension UUIDKeyedMap {
    subscript(id: Identifier<Tag>) -> Value? {
        get { entries[id] }
        set { entries[id] = newValue }
    }

    var count: Int {
        entries.count
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    var keys: Dictionary<Identifier<Tag>, Value>.Keys {
        entries.keys
    }

    var values: Dictionary<Identifier<Tag>, Value>.Values {
        entries.values
    }
}

extension UUIDKeyedMap: Decodable where Value: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var result: [Identifier<Tag>: Value] = [:]
        result.reserveCapacity(container.allKeys.count)
        for key in container.allKeys {
            let raw = key.stringValue
            guard let identifier = Identifier<Tag>(codingKey: key) else {
                let context = DecodingError.Context(
                    codingPath: container.codingPath + [key],
                    debugDescription: "Invalid UUID map key \"\(raw)\": expected the exact "
                        + "canonical lowercase-hyphenated UUID text the backend emits"
                )
                throw DecodingError.dataCorrupted(context)
            }
            guard result[identifier] == nil else {
                let context = DecodingError.Context(
                    codingPath: container.codingPath + [key],
                    debugDescription: "Duplicate UUID map key \"\(raw)\" after normalization"
                )
                throw DecodingError.dataCorrupted(context)
            }
            result[identifier] = try container.decode(Value.self, forKey: key)
        }
        entries = result
    }
}

extension UUIDKeyedMap: Encodable where Value: Encodable {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        for (identifier, value) in entries {
            let key = AnyCodingKey(stringValue: identifier.codingKey.stringValue)
            try container.encode(value, forKey: key)
        }
    }
}
