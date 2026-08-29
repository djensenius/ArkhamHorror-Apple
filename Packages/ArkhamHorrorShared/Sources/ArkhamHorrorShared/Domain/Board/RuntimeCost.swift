/// `Arkham.Cost.Cost` (`backend/arkham-api/library/Arkham/Cost.hs`), derived with Aeson's
/// default sum encoding: because `Cost` has constructors with arguments,
/// `allNullaryToStringTag` does not apply, so every constructor — including nullary ones
/// like `Free` — encodes as a `TaggedObject` (`{"tag": ...}`, with a `contents` key added
/// only for constructors that carry data).
///
/// This models the backend schema's closed top-level `{tag, contents?}` envelope (its
/// `cost.schema.json` declares `additionalProperties: false`: only `tag` plus an optional
/// `contents` are ever emitted) while deliberately leaving `contents` itself unconstrained:
/// `Cost` is a broad tagged union — dozens of constructors covering action/resource/clue/
/// discard/matcher-driven costs — and its per-constructor payload shape stays
/// intentionally out of scope for this contract slice. Matching this codebase's
/// established forward-compatible convention for response-only types, this decoder itself
/// does not reject an unrecognized additional key (see ``ChaosBagPhaseStepPlacementTests``
/// for that behavior exercised directly); it is not a contract-boundary enforcement point.
/// Used by `Act.advanceCost`, `Location.costToEnterUnrevealed`, and
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
