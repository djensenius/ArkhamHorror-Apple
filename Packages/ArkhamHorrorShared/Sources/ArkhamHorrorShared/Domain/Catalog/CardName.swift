/// A display name pair: a required `title` and a nullable `subtitle`.
///
/// Shared by `CardDef.name`/`.revealedName` and, in the game-list contract, scenario
/// summary names — both use the identical `{title, subtitle}` shape.
struct CardName: Sendable, Equatable, Hashable, Codable {
    let title: String
    let subtitle: String?
}
