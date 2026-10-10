import Foundation

/// Native create-game catalog as served by `GET /api/v1/arkham/campaign-catalog`.
///
/// The endpoint's v1 contract deliberately leaves settings, variants and recommended
/// options as untyped JSON arrays. This model validates the closed envelope and the stable
/// identifiers/name keys this client needs, preserves those untyped arrays losslessly, and
/// drops only malformed individual campaign/scenario entries so one bad record cannot make a
/// previously usable catalog entry unsafe to display.
struct CampaignCatalogDocument: Sendable, Equatable {
    let schemaVersion: String
    let catalogRevision: String
    let endpoint: String
    let digestAlgorithm: String
    let campaigns: [CampaignCatalogCampaign]
    let scenarios: [CampaignCatalogScenario]
    let sideStories: [CampaignCatalogScenario]
}

struct CampaignCatalogCampaign: Sendable, Equatable, Hashable {
    let id: String
    let nameKey: String
    let alpha: Bool
    let beta: Bool
    let dev: Bool
    let chapter: Int?
    let returnTo: CampaignCatalogReturnToCampaign?
    let variants: [CampaignCatalogVariant]
    let recommendedOptions: [CampaignCatalogRecommendedOption]
    let settings: [JSONValue]
}

struct CampaignCatalogReturnToCampaign: Sendable, Equatable, Hashable {
    let id: String
    let nameKey: String
    let alpha: Bool
    let beta: Bool
    let dev: Bool
}

struct CampaignCatalogScenario: Sendable, Equatable, Hashable {
    let id: String
    let nameKey: String
    let campaignID: String?
    let alpha: Bool
    let beta: Bool
    let dev: Bool
    let show: Bool
    let standalone: Bool
    let returnToID: String?
    let returnToNameKey: String?
    let returnToVariant: Bool
    let standaloneDifficulties: [RequestDifficulty]?
    let requiredInvestigator: String?
    let requiredInvestigatorCodes: [String]
    let deckRequirements: [String]
    let settings: [JSONValue]
    let parts: [CampaignCatalogSideStoryPart]
}

struct CampaignCatalogSideStoryPart: Sendable, Equatable, Hashable {
    let id: String
    let nameKey: String
    let box: String?
}

struct CampaignCatalogVariant: Sendable, Equatable, Hashable {
    let key: String
    let raw: JSONValue
}

struct CampaignCatalogRecommendedOption: Sendable, Equatable, Hashable {
    let tag: String
    let defaultEnabled: Bool
    let raw: JSONValue
}

enum CampaignCatalogDecodeError: Error, Equatable, Sendable {
    case malformedStructure
}

private struct FailableCatalogEntry<Entry: Decodable>: Decodable {
    let value: Entry?

    init(from decoder: any Decoder) throws {
        value = try? Entry(from: decoder)
    }
}

extension CampaignCatalogDocument: Decodable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case catalogRevision
        case endpoint
        case digestAlgorithm
        case campaigns
        case scenarios
        case sideStories
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        catalogRevision = try container.decode(String.self, forKey: .catalogRevision)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        digestAlgorithm = try container.decode(String.self, forKey: .digestAlgorithm)
        guard schemaVersion == "1.0.0",
              endpoint == "/api/v1/arkham/campaign-catalog",
              digestAlgorithm == "sha256"
        else { throw CampaignCatalogDecodeError.malformedStructure }
        campaigns = try Self.decodeLossyArray(CampaignCatalogCampaign.self, from: container, key: .campaigns) // swiftlint:disable:this line_length
        scenarios = try Self.decodeLossyArray(CampaignCatalogScenario.self, from: container, key: .scenarios) // swiftlint:disable:this line_length
        sideStories = try Self.decodeLossyArray(CampaignCatalogScenario.self, from: container, key: .sideStories) // swiftlint:disable:this line_length
        guard !campaigns.isEmpty || !scenarios.isEmpty || !sideStories.isEmpty else {
            throw CampaignCatalogDecodeError.malformedStructure
        }
    }

    private static func decodeLossyArray<Entry: Decodable>(
        _: Entry.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> [Entry] {
        var nested = try container.nestedUnkeyedContainer(forKey: key)
        var decoded: [Entry] = []
        while !nested.isAtEnd {
            if let entry = try nested.decode(FailableCatalogEntry<Entry>.self).value {
                decoded.append(entry)
            }
        }
        return decoded
    }
}

extension CampaignCatalogCampaign: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case nameKey
        case alpha
        case beta
        case dev
        case chapter
        case returnTo
        case variants
        case recommendedOptions
        case settings
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.requireIdentifier(container.decode(String.self, forKey: .id))
        nameKey = try Self.requireCatalogNameKey(container.decode(String.self, forKey: .nameKey))
        alpha = try container.decodeIfPresent(Bool.self, forKey: .alpha) ?? false
        beta = try container.decodeIfPresent(Bool.self, forKey: .beta) ?? false
        dev = try container.decodeIfPresent(Bool.self, forKey: .dev) ?? false
        let decodedChapter = try container.decodeIfPresent(Int.self, forKey: .chapter)
        chapter = decodedChapter == 1 || decodedChapter == 2 ? decodedChapter : nil
        returnTo = try container.decodeIfPresent(CampaignCatalogReturnToCampaign.self, forKey: .returnTo) // swiftlint:disable:this line_length
        variants = try Self.decodeJSONList(
            container.decodeIfPresent([JSONValue].self, forKey: .variants) ?? []
        ).compactMap(CampaignCatalogVariant.init(raw:))
        recommendedOptions = try Self.decodeJSONList(
            container.decodeIfPresent([JSONValue].self, forKey: .recommendedOptions) ?? []
        ).compactMap(CampaignCatalogRecommendedOption.init(raw:))
        settings = try container.decodeIfPresent([JSONValue].self, forKey: .settings) ?? []
    }
}

extension CampaignCatalogReturnToCampaign: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case nameKey
        case alpha
        case beta
        case dev
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try CampaignCatalogCampaign.requireIdentifier(container.decode(String.self, forKey: .id)) // swiftlint:disable:this line_length
        nameKey = try CampaignCatalogCampaign.requireCatalogNameKey(
            container.decode(String.self, forKey: .nameKey)
        )
        alpha = try container.decodeIfPresent(Bool.self, forKey: .alpha) ?? false
        beta = try container.decodeIfPresent(Bool.self, forKey: .beta) ?? false
        dev = try container.decodeIfPresent(Bool.self, forKey: .dev) ?? false
    }
}

extension CampaignCatalogScenario: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case nameKey
        case campaign
        case alpha
        case beta
        case dev
        case show
        case standalone
        case returnTo
        case returnToNameKey
        case returnToVariant
        case standaloneDifficulties
        case requiredInvestigator
        case requiredInvestigatorCodes
        case deckRequirements
        case settings
        case scenarios
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try CampaignCatalogCampaign.requireIdentifier(container.decode(String.self, forKey: .id)) // swiftlint:disable:this line_length
        nameKey = try CampaignCatalogCampaign.requireCatalogNameKey(
            container.decode(String.self, forKey: .nameKey)
        )
        campaignID = try container.decodeIfPresent(String.self, forKey: .campaign)
        alpha = try container.decodeIfPresent(Bool.self, forKey: .alpha) ?? false
        beta = try container.decodeIfPresent(Bool.self, forKey: .beta) ?? false
        dev = try container.decodeIfPresent(Bool.self, forKey: .dev) ?? false
        show = try container.decodeIfPresent(Bool.self, forKey: .show) ?? true
        standalone = try container.decodeIfPresent(Bool.self, forKey: .standalone) ?? true
        let decodedReturnToID = try container.decodeIfPresent(String.self, forKey: .returnTo)
        let decodedReturnToNameKey = try container.decodeIfPresent(
            String.self, forKey: .returnToNameKey
        )
        switch (decodedReturnToID, decodedReturnToNameKey) {
        case (nil, nil):
            returnToID = nil
            returnToNameKey = nil
        case let (id?, nameKey?):
            returnToID = try CampaignCatalogCampaign.requireIdentifier(id)
            returnToNameKey = try CampaignCatalogCampaign.requireCatalogNameKey(nameKey)
        default:
            throw CampaignCatalogDecodeError.malformedStructure
        }
        returnToVariant = try container.decodeIfPresent(
            Bool.self, forKey: .returnToVariant
        ) ?? false
        standaloneDifficulties = try container.decodeIfPresent(
            [RequestDifficulty].self, forKey: .standaloneDifficulties
        )
        requiredInvestigator = try container.decodeIfPresent(String.self, forKey: .requiredInvestigator) // swiftlint:disable:this line_length
        requiredInvestigatorCodes = try container.decodeIfPresent(
            [String].self, forKey: .requiredInvestigatorCodes
        ) ?? []
        deckRequirements = try container.decodeIfPresent(
            [String].self, forKey: .deckRequirements
        ) ?? []
        settings = try container.decodeIfPresent([JSONValue].self, forKey: .settings) ?? []
        parts = try container.decodeIfPresent([CampaignCatalogSideStoryPart].self, forKey: .scenarios) ?? [] // swiftlint:disable:this line_length
    }
}

extension CampaignCatalogSideStoryPart: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case nameKey
        case box
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try CampaignCatalogCampaign.requireIdentifier(container.decode(String.self, forKey: .id)) // swiftlint:disable:this line_length
        nameKey = try CampaignCatalogCampaign.requireCatalogNameKey(
            container.decode(String.self, forKey: .nameKey)
        )
        box = try container.decodeIfPresent(String.self, forKey: .box)
    }
}

private extension CampaignCatalogCampaign {
    static func requireIdentifier(_ id: String) throws -> String {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CampaignCatalogDecodeError.malformedStructure
        }
        return id
    }

    static func requireCatalogNameKey(_ key: String) throws -> String {
        let prefix = "catalogNames."
        guard key.hasPrefix(prefix), key.count > prefix.count else {
            throw CampaignCatalogDecodeError.malformedStructure
        }
        return key
    }

    static func decodeJSONList(_ values: [JSONValue]) throws -> [JSONValue] {
        values
    }
}

private extension CampaignCatalogVariant {
    init?(raw: JSONValue) {
        guard case let .object(object) = raw,
              case let .string(key)? = object["key"],
              !key.isEmpty
        else { return nil }
        self.init(key: key, raw: raw)
    }
}

private extension CampaignCatalogRecommendedOption {
    init?(raw: JSONValue) {
        guard case let .object(object) = raw,
              case .string("toggle")? = object["type"],
              case let .object(option)? = object["option"],
              case let .string(tag)? = option["tag"],
              !tag.isEmpty
        else { return nil }
        let defaultEnabled: Bool = if case let .bool(value) = object["default"] {
            value
        } else {
            true
        }
        self.init(tag: tag, defaultEnabled: defaultEnabled, raw: raw)
    }
}
