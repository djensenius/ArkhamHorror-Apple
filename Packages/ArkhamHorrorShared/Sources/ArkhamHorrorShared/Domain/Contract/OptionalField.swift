/// A tri-state wrapper for defaultable request fields where the wire distinguishes an
/// absent key, an explicit `null`, and an explicit value.
///
/// `CreateGameRequest`'s `strictAsIfAt`, `asIfRuling`, `ultimatumsAndBoons`, and
/// `achievementsEnabled` each have a documented server-side default applied only when the
/// key is entirely absent. Plain `Optional` cannot express this distinction: both
/// `Keyed*Container.decodeIfPresent` and `encodeIfPresent` treat a missing key and an
/// explicit `null` identically.
enum OptionalField<Value: Sendable>: Sendable {
    /// The key was not present in the JSON object; the server applies its own default.
    case absent
    /// The key was present with an explicit JSON `null` value.
    case null
    /// The key was present with a decoded value.
    case value(Value)
}

extension OptionalField: Equatable where Value: Equatable {}
extension OptionalField: Hashable where Value: Hashable {}

extension OptionalField {
    /// `nil` for `.absent`/`.null`, the payload for `.value`.
    var valueOrNil: Value? {
        if case let .value(value) = self {
            return value
        }
        return nil
    }
}

extension OptionalField where Value: Decodable {
    /// Decodes an `OptionalField` for `key` from `container`, distinguishing an absent
    /// key, an explicit `null`, and a present value.
    static func decode<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> OptionalField<Value> {
        guard container.contains(key) else { return .absent }
        if try container.decodeNil(forKey: key) {
            return .null
        }
        return try .value(container.decode(Value.self, forKey: key))
    }
}

extension OptionalField where Value: Encodable {
    /// Encodes this `OptionalField` into `container` at `key`: omits the key entirely for
    /// `.absent`, emits JSON `null` for `.null`, and encodes the payload for `.value`.
    func encode<Key: CodingKey>(
        to container: inout KeyedEncodingContainer<Key>,
        forKey key: Key
    ) throws {
        switch self {
        case .absent:
            break
        case .null:
            try container.encodeNil(forKey: key)
        case let .value(value):
            try container.encode(value, forKey: key)
        }
    }
}
