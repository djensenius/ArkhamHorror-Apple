/// Phantom tag distinguishing ``AsIfRulingSetting``.
enum AsIfRulingSettingTag: Sendable {}
/// `GameSettings.settingsAsIfRuling`'s chapter-ruling value. Distinct from
/// `CampaignOption.swift`'s request-side `AsIfRuling` (whose wire values —
/// `Chapter1AsIfRuling`/`Chapter2AsIfRuling` — differ textually from this response-side
/// field's `chapter1`/`chapter2`): this is a response-side field, so it stays forward
/// compatible with values this client build doesn't yet know about.
typealias AsIfRulingSetting = OpenStringEnum<AsIfRulingSettingTag>

extension AsIfRulingSetting {
    static let chapter1 = AsIfRulingSetting("chapter1")
    static let chapter2 = AsIfRulingSetting("chapter2")
}

/// `PublicGame.settings`/`.gameSettings` (both fields share the identical shape).
struct GameSettings: Sendable {
    let abilitiesCannotReactToThemselves: Bool
    let achievementsEnabled: Bool
    let asIfRuling: AsIfRulingSetting
    let rolledUltimatumOrBoon: String?
    let screamedAllies: [String]
    let strictAsIfAt: Bool
    let ultimatumsAndBoons: [String]
    let ultimatumsAndBoonsEnabled: Bool
}

extension GameSettings: Equatable, Hashable {}

extension GameSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case abilitiesCannotReactToThemselves = "settingsAbilitiesCannotReactToThemselves"
        case achievementsEnabled = "settingsAchievementsEnabled"
        case asIfRuling = "settingsAsIfRuling"
        case rolledUltimatumOrBoon = "settingsRolledUltimatumOrBoon"
        case screamedAllies = "settingsScreamedAllies"
        case strictAsIfAt = "settingsStrictAsIfAt"
        case ultimatumsAndBoons = "settingsUltimatumsAndBoons"
        case ultimatumsAndBoonsEnabled = "settingsUltimatumsAndBoonsEnabled"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        abilitiesCannotReactToThemselves = try container.decode(
            Bool.self, forKey: .abilitiesCannotReactToThemselves
        )
        achievementsEnabled = try container.decode(Bool.self, forKey: .achievementsEnabled)
        asIfRuling = try container.decode(AsIfRulingSetting.self, forKey: .asIfRuling)
        rolledUltimatumOrBoon = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .rolledUltimatumOrBoon,
            codingPath: decoder.codingPath + [CodingKeys.rolledUltimatumOrBoon]
        )
        screamedAllies = try container.decode([String].self, forKey: .screamedAllies)
        strictAsIfAt = try container.decode(Bool.self, forKey: .strictAsIfAt)
        ultimatumsAndBoons = try container.decode([String].self, forKey: .ultimatumsAndBoons)
        ultimatumsAndBoonsEnabled = try container.decode(
            Bool.self, forKey: .ultimatumsAndBoonsEnabled
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            abilitiesCannotReactToThemselves, forKey: .abilitiesCannotReactToThemselves
        )
        try container.encode(achievementsEnabled, forKey: .achievementsEnabled)
        try container.encode(asIfRuling, forKey: .asIfRuling)
        try container.encode(rolledUltimatumOrBoon, forKey: .rolledUltimatumOrBoon)
        try container.encode(screamedAllies, forKey: .screamedAllies)
        try container.encode(strictAsIfAt, forKey: .strictAsIfAt)
        try container.encode(ultimatumsAndBoons, forKey: .ultimatumsAndBoons)
        try container.encode(ultimatumsAndBoonsEnabled, forKey: .ultimatumsAndBoonsEnabled)
    }
}
