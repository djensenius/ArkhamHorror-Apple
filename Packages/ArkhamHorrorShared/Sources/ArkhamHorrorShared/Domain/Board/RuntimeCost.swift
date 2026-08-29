/// `Arkham.Cost.Cost` (`backend/arkham-api/library/Arkham/Cost.hs`), derived with Aeson's
/// default sum encoding: because `Cost` has constructors with arguments,
/// `allNullaryToStringTag` does not apply, so every constructor — including nullary ones
/// like `Free` — encodes as a `TaggedObject` (`{"tag": ...}`, with a `contents` key added
/// only for constructors that carry data).
///
/// This asserts the closed top-level `{tag, contents?}` envelope (only `tag` plus an
/// optional `contents` are permitted; unknown keys fail closed) while deliberately leaving
/// `contents` unconstrained: `Cost` is a broad tagged union — dozens of constructors
/// covering action/resource/clue/discard/matcher-driven costs — and its per-constructor
/// payload shape stays intentionally out of scope for this contract slice. Used by
/// `Act.advanceCost`, `Location.costToEnterUnrevealed`, and
/// `Movement.moveAdditionalEnterCosts`.
struct RuntimeCost: Sendable {
    let tag: String
    let contents: JSONValue?
}

extension RuntimeCost: Equatable, Hashable {}

extension RuntimeCost: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        contents = try container.decodeIfPresent(JSONValue.self, forKey: .contents)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        try container.encodeIfPresent(contents, forKey: .contents)
    }
}
