/// Phantom tag distinguishing ``CampaignOptionFlag``.
enum CampaignOptionFlagTag: Sendable {}
/// One of the campaign option flags with no associated content (see
/// ``CampaignOption/flag(_:)``).
///
/// There are 32 known flags. To keep this file's size manageable, individual named
/// accessors are intentionally omitted; construct a flag with
/// `CampaignOptionFlag("PerformIntro")` when needed.
typealias CampaignOptionFlag = OpenStringEnum<CampaignOptionFlagTag>

/// The complete set of campaign option tags this client build recognizes as no-content
/// flags. A tag outside this set (other than `CampaignVariant`) decodes as
/// ``CampaignOption/unknown(tag:contents:)`` instead, so a genuinely unrecognized option
/// can never be silently treated as a known flag.
private let knownCampaignOptionFlagTags: Set<String> = [
    "PerformIntro",
    "PlayersDoNotControlStoryAssetClues",
    "AddLitaChantler",
    "Cheated",
    "TakeArmitage",
    "TakeWarrenRice",
    "TakeFrancisMorgan",
    "TakeZebulonWhately",
    "TakeEarlSawyer",
    "TakePowderOfIbnGhazi",
    "TakeTheNecronomicon",
    "AddAcrossSpaceAndTime",
    "UseSwarmPlaceholders",
    "TakeBlackBook",
    "TakePuzzleBox",
    "ProceedToInterlude3",
    "DebugOption",
    "ManuallyPickCamp",
    "ManuallyPickKilledInPlaneCrash",
    "AddGreenSoapstone",
    "AddWoodenSledge",
    "AddDynamite",
    "AddMiasmicCrystal",
    "AddMineralSpecimen",
    "AddSmallRadio",
    "AddSpareParts",
    "IncludePartners",
    "FatalMiragePart1",
    "FatalMiragePart2",
    "FatalMiragePart3",
    "PlayAsMiniCampaign",
    "PlayWithTheBlobThatAteEverythingElse",
]

/// Phantom tag distinguishing ``UltimatumOrBoon``.
enum UltimatumOrBoonTag: Sendable {}
/// One of the ~30 known ultimatum/boon string values used by
/// `CreateGameRequest.ultimatumsAndBoons`, forward-compatible with future additions.
typealias UltimatumOrBoon = OpenStringEnum<UltimatumOrBoonTag>

/// Phantom tag distinguishing ``AsIfRuling``.
enum AsIfRulingTag: Sendable {}
/// `CreateGameRequest.asIfRuling`'s chapter-ruling override.
typealias AsIfRuling = OpenStringEnum<AsIfRulingTag>

extension AsIfRuling {
    static let chapter1 = AsIfRuling("chapter1")
    static let chapter2 = AsIfRuling("chapter2")
    static let chapter1AsIfRuling = AsIfRuling("Chapter1AsIfRuling")
    static let chapter2AsIfRuling = AsIfRuling("Chapter2AsIfRuling")
}

/// One entry of `CreateGameRequest.options`.
///
/// Decoding discriminates against an explicit, closed set of known flag tags (rather than
/// relying on ``OpenStringEnum``'s inherent permissiveness), so a genuinely unrecognized
/// tag becomes ``unknown(tag:contents:)`` and can never be accidentally treated as, or
/// resubmitted as, a known flag or variant.
enum CampaignOption: Sendable {
    /// A no-content campaign option flag.
    case flag(CampaignOptionFlag)
    /// A named campaign variant, for example `"return-to"`.
    case campaignVariant(String)
    /// A tag not recognized by this client build.
    case unknown(tag: String, contents: JSONValue?)
}

extension CampaignOption: Equatable, Hashable {}

extension CampaignOption: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        if tag == "CampaignVariant" {
            self = try .campaignVariant(container.decode(String.self, forKey: .contents))
        } else if knownCampaignOptionFlagTags.contains(tag) {
            self = .flag(CampaignOptionFlag(tag))
        } else {
            let contents = try container.decodeIfPresent(JSONValue.self, forKey: .contents)
            self = .unknown(tag: tag, contents: contents)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .flag(flag):
            try container.encode(flag.rawValue, forKey: .tag)
        case let .campaignVariant(variant):
            try container.encode("CampaignVariant", forKey: .tag)
            try container.encode(variant, forKey: .contents)
        case let .unknown(tag, contents):
            try container.encode(tag, forKey: .tag)
            try container.encodeIfPresent(contents, forKey: .contents)
        }
    }
}
