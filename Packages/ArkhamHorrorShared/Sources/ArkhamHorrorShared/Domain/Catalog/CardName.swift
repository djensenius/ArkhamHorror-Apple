/// A display name pair: a required `title` and a nullable `subtitle`.
///
/// Shared by `CardDef.name`/`.revealedName` and, in the game-list contract, scenario
/// summary names — both use the identical `{title, subtitle}` shape.
struct CardName: Sendable, Equatable, Hashable {
    let title: String
    let subtitle: String?
}

extension CardName: Codable {
    private enum CodingKeys: String, CodingKey {
        case title
        case subtitle
    }

    /// `subtitle` is required by the schema (`required: [title, subtitle]`) but nullable:
    /// a missing key is a contract violation, while an explicit `null` is the normal way a
    /// card without a subtitle is represented.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .subtitle,
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        // Non-`IfPresent` encode so `nil` produces an explicit `null` rather than omitting
        // the key, matching the always-present wire shape.
        try container.encode(subtitle, forKey: .subtitle)
    }
}
