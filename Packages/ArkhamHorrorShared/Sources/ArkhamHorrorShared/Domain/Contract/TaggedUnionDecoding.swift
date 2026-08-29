/// Throws if `container` contains a `"contents"` key — present at all, even explicit
/// `null` — for a tag the contract declares as carrying no contents whatsoever (schema
/// `additionalProperties: false` with only `tag` in `required`/`properties`). Used by the
/// nullary cases of tagged-union types such as ``CardCost``, ``GameValue``, ``SkillIcon``,
/// and ``GameState`` so a payload that illegally attaches a `contents` key to one of these
/// tags is rejected rather than silently ignored.
func rejectPresentContents<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    contentsKey: Key,
    tag: String,
    codingPath: [any CodingKey]
) throws {
    guard !container.contains(contentsKey) else {
        let context = DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Tag \"\(tag)\" does not accept a \"contents\" key, even null"
        )
        throw DecodingError.dataCorrupted(context)
    }
}
