/// Decodes an optional key the contract's schema types strictly (for example
/// `{"type": "integer"}` or an enum), never including `null` in its declared type union.
/// The key may be absent — the property simply isn't used by this card — but if present,
/// its value must actually satisfy the declared type; an explicit JSON `null` is rejected
/// rather than silently collapsed to the same `nil` an absent key would produce.
///
/// Plain `decodeIfPresent` cannot distinguish "absent" from "present but null": both
/// currently succeed and both produce `nil`. That is the correct behavior for a field the
/// schema explicitly types as nullable (see ``decodeRequiredNullable``'s required-nullable
/// counterpart) but the wrong behavior for a field the schema never allows to be null at
/// all.
func decodeAbsentOnly<Key: CodingKey, Value: Decodable>(
    _: Value.Type,
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key,
    codingPath: [any CodingKey]
) throws -> Value? {
    guard container.contains(key) else { return nil }
    if try container.decodeNil(forKey: key) {
        let context = DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Key \"\(key.stringValue)\" does not accept an explicit null; "
                + "omit the key entirely instead"
        )
        throw DecodingError.dataCorrupted(context)
    }
    return try container.decode(Value.self, forKey: key)
}
