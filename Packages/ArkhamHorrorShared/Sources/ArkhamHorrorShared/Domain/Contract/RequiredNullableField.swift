/// Decodes a key the contract's schema marks required but nullable: the key itself must be
/// present on the wire (a missing key is a contract violation), while its value may be an
/// explicit JSON `null`. Plain `decodeIfPresent` alone cannot distinguish "missing" from
/// "present and null" — both collapse to `nil` — so presence is checked explicitly first.
///
/// Pair with a plain (non-`IfPresent`) `container.encode(value, forKey:)` on the encode
/// side so `nil` re-encodes as an explicit `null` rather than omitting the key.
func decodeRequiredNullable<Key: CodingKey, Value: Decodable>(
    _: Value.Type,
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key,
    codingPath: [any CodingKey]
) throws -> Value? {
    guard container.contains(key) else {
        let context = DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Missing required key \"\(key.stringValue)\"; the backend "
                + "always includes this key, using null rather than omitting it"
        )
        throw DecodingError.keyNotFound(key, context)
    }
    return try container.decodeIfPresent(Value.self, forKey: key)
}
