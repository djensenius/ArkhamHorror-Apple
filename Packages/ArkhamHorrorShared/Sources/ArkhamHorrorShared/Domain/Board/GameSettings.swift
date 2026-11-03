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
    /// Schema 0.1.57 `settingsCustomRandomWeaknessPools`, keyed by player. `nil` when an
    /// older server omits the key, so re-encoding never invents it.
    var customRandomWeaknessPools: UUIDKeyedMap<PlayerIDTag, CustomRandomWeaknessPool>?
}

extension GameSettings: Equatable, Hashable {}

/// One player's custom random basic weakness pool, encoded on the wire as a 2-element
/// `[enabled, cardCodes]` array.
struct CustomRandomWeaknessPool: Sendable, Equatable, Hashable {
    let enabled: Bool
    let cardCodes: [String]
}

extension CustomRandomWeaknessPool: Codable {
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        enabled = try container.decode(Bool.self)
        cardCodes = try container.decode([String].self)
        guard container.isAtEnd else {
            let context = DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Expected exactly 2 elements for a custom weakness pool"
            )
            throw DecodingError.dataCorrupted(context)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(enabled)
        try container.encode(cardCodes)
    }
}

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
        case customRandomWeaknessPools = "settingsCustomRandomWeaknessPools"
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
        customRandomWeaknessPools = try container.decodePresentIfContained(
            UUIDKeyedMap<PlayerIDTag, CustomRandomWeaknessPool>.self,
            forKey: .customRandomWeaknessPools
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
        try container.encodeIfPresent(
            customRandomWeaknessPools, forKey: .customRandomWeaknessPools
        )
    }
}
