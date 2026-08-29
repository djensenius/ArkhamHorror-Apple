import Foundation

/// `CreateGameRequest.difficulty`'s value. A closed, validated enum: this is a request-side
/// field, and the exact backend build this client targets only accepts these 4 values.
/// Distinct from `GameListModels.swift`'s response-side `Difficulty` (an ``OpenStringEnum``,
/// which must stay forward-compatible with server-reported difficulties this client build
/// doesn't yet know about) — an unknown value decoded from a response can never be fed
/// directly back into a request field of this type.
enum RequestDifficulty: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case easy = "Easy"
    case standard = "Standard"
    case hard = "Hard"
    case expert = "Expert"
}

/// `CreateGameRequest.multiplayerVariant`'s value. A closed, validated enum, analogous to
/// ``RequestDifficulty``: distinct from the response-side ``MultiplayerVariant``.
enum RequestMultiplayerVariant: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case solo = "Solo"
    case withFriends = "WithFriends"
}

/// The error thrown when encoding a ``CreateGameRequest`` whose `campaignId` and
/// `scenarioId` are both absent or empty, violating the contract's invariant that at least
/// one of the two must be present as a non-empty string.
enum CreateGameRequestError: Error, Equatable, Sendable {
    case missingCampaignOrScenario
}

/// A request to create a new game.
///
/// `strictAsIfAt`, `asIfRuling`, `ultimatumsAndBoons`, and `achievementsEnabled` are
/// tri-state: an absent key lets the server apply its own default, while an explicit
/// `null` opts out of that default. `campaignId`/`scenarioId` are always both written to
/// the wire (one as `null`), and encoding enforces — immediately before either is written —
/// that at least one is a non-empty string, matching the contract's `anyOf` invariant.
struct CreateGameRequest: Sendable {
    let deckIds: [DeckID?]
    let playerCount: Int
    let campaignId: String?
    let scenarioId: String?
    let difficulty: RequestDifficulty
    let campaignName: String
    let multiplayerVariant: RequestMultiplayerVariant
    let includeTarotReadings: Bool
    let options: [CampaignOption]
    let strictAsIfAt: OptionalField<Bool>
    let asIfRuling: OptionalField<AsIfRuling>
    let ultimatumsAndBoons: OptionalField<[UltimatumOrBoon]>
    let achievementsEnabled: OptionalField<Bool>
}

extension CreateGameRequest: Equatable {}

extension CreateGameRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case deckIds
        case playerCount
        case campaignId
        case scenarioId
        case difficulty
        case campaignName
        case multiplayerVariant
        case includeTarotReadings
        case options
        case strictAsIfAt
        case asIfRuling
        case ultimatumsAndBoons
        case achievementsEnabled
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deckIds = try container.decode([DeckID?].self, forKey: .deckIds)
        playerCount = try container.decode(Int.self, forKey: .playerCount)
        campaignId = try container.decodeIfPresent(String.self, forKey: .campaignId)
        scenarioId = try container.decodeIfPresent(String.self, forKey: .scenarioId)
        difficulty = try container.decode(RequestDifficulty.self, forKey: .difficulty)
        campaignName = try container.decode(String.self, forKey: .campaignName)
        multiplayerVariant = try container.decode(
            RequestMultiplayerVariant.self,
            forKey: .multiplayerVariant
        )
        includeTarotReadings = try container.decode(Bool.self, forKey: .includeTarotReadings)
        options = try container.decode([CampaignOption].self, forKey: .options)
        strictAsIfAt = try OptionalField<Bool>.decode(from: container, forKey: .strictAsIfAt)
        asIfRuling = try OptionalField<AsIfRuling>.decode(from: container, forKey: .asIfRuling)
        ultimatumsAndBoons = try OptionalField<[UltimatumOrBoon]>.decode(
            from: container,
            forKey: .ultimatumsAndBoons
        )
        achievementsEnabled = try OptionalField<Bool>.decode(
            from: container,
            forKey: .achievementsEnabled
        )
    }

    func encode(to encoder: any Encoder) throws {
        guard Self.isNonEmpty(campaignId) || Self.isNonEmpty(scenarioId) else {
            throw CreateGameRequestError.missingCampaignOrScenario
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deckIds, forKey: .deckIds)
        try container.encode(playerCount, forKey: .playerCount)
        try Self.encodeNullable(campaignId, in: &container, forKey: .campaignId)
        try Self.encodeNullable(scenarioId, in: &container, forKey: .scenarioId)
        try container.encode(difficulty, forKey: .difficulty)
        try container.encode(campaignName, forKey: .campaignName)
        try container.encode(multiplayerVariant, forKey: .multiplayerVariant)
        try container.encode(includeTarotReadings, forKey: .includeTarotReadings)
        try container.encode(options, forKey: .options)
        try strictAsIfAt.encode(to: &container, forKey: .strictAsIfAt)
        try asIfRuling.encode(to: &container, forKey: .asIfRuling)
        try ultimatumsAndBoons.encode(to: &container, forKey: .ultimatumsAndBoons)
        try achievementsEnabled.encode(to: &container, forKey: .achievementsEnabled)
    }

    private static func isNonEmpty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty
    }

    private static func encodeNullable(
        _ value: String?,
        in container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}
