/// One of the 32 known campaign option flags with no associated content (see
/// ``CampaignOption/flag(_:)``). A closed, validated enum: unlike ``OpenStringEnum``, an
/// unrecognized raw string cannot be constructed — decoding throws, and there is no
/// programmatic way to build one — so a `.flag` can never wrap, or be re-submitted with, a
/// tag this client build doesn't actually recognize.
enum CampaignOptionFlag: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case performIntro = "PerformIntro"
    case playersDoNotControlStoryAssetClues = "PlayersDoNotControlStoryAssetClues"
    case addLitaChantler = "AddLitaChantler"
    case cheated = "Cheated"
    case takeArmitage = "TakeArmitage"
    case takeWarrenRice = "TakeWarrenRice"
    case takeFrancisMorgan = "TakeFrancisMorgan"
    case takeZebulonWhately = "TakeZebulonWhately"
    case takeEarlSawyer = "TakeEarlSawyer"
    case takePowderOfIbnGhazi = "TakePowderOfIbnGhazi"
    case takeTheNecronomicon = "TakeTheNecronomicon"
    case addAcrossSpaceAndTime = "AddAcrossSpaceAndTime"
    case useSwarmPlaceholders = "UseSwarmPlaceholders"
    case takeBlackBook = "TakeBlackBook"
    case takePuzzleBox = "TakePuzzleBox"
    case proceedToInterlude3 = "ProceedToInterlude3"
    case debugOption = "DebugOption"
    case manuallyPickCamp = "ManuallyPickCamp"
    case manuallyPickKilledInPlaneCrash = "ManuallyPickKilledInPlaneCrash"
    case addGreenSoapstone = "AddGreenSoapstone"
    case addWoodenSledge = "AddWoodenSledge"
    case addDynamite = "AddDynamite"
    case addMiasmicCrystal = "AddMiasmicCrystal"
    case addMineralSpecimen = "AddMineralSpecimen"
    case addSmallRadio = "AddSmallRadio"
    case addSpareParts = "AddSpareParts"
    case includePartners = "IncludePartners"
    case fatalMiragePart1 = "FatalMiragePart1"
    case fatalMiragePart2 = "FatalMiragePart2"
    case fatalMiragePart3 = "FatalMiragePart3"
    case playAsMiniCampaign = "PlayAsMiniCampaign"
    case playWithTheBlobThatAteEverythingElse = "PlayWithTheBlobThatAteEverythingElse"
}

/// One of the 30 known ultimatum/boon string values used by
/// `CreateGameRequest.ultimatumsAndBoons`. A closed, validated enum, unlike
/// ``OpenStringEnum``: this is a request-side field, and the exact backend build this
/// client targets only accepts these 30 values, so an unrecognized string must never be
/// constructible or encodable here.
enum UltimatumOrBoon: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case boonOfTheAncients = "BoonOfTheAncients"
    case boonOfAthena = "BoonOfAthena"
    case boonOfDestiny = "BoonOfDestiny"
    case boonOfHades = "BoonOfHades"
    case boonOfHermes = "BoonOfHermes"
    case boonOfThoth = "BoonOfThoth"
    case boonOfOsiris = "BoonOfOsiris"
    case boonOfTheMorrigan = "BoonOfTheMorrigan"
    case boonOfPersephone = "BoonOfPersephone"
    case boonOfTheExplorer = "BoonOfTheExplorer"
    case boonOfTheChild = "BoonOfTheChild"
    case ultimatumOfAgony = "UltimatumOfAgony"
    case ultimatumOfBrokenPromises = "UltimatumOfBrokenPromises"
    case ultimatumOfTheBrokenVeil = "UltimatumOfTheBrokenVeil"
    case ultimatumOfChaos = "UltimatumOfChaos"
    case ultimatumOfDisaster = "UltimatumOfDisaster"
    case ultimatumOfDread = "UltimatumOfDread"
    case ultimatumOfFailure = "UltimatumOfFailure"
    case ultimatumOfFinality = "UltimatumOfFinality"
    case ultimatumOfForbiddenKnowledge = "UltimatumOfForbiddenKnowledge"
    case ultimatumOfHardship = "UltimatumOfHardship"
    case ultimatumOfTheHighlander = "UltimatumOfTheHighlander"
    case ultimatumOfInduction = "UltimatumOfInduction"
    case ultimatumOfOrthodoxy = "UltimatumOfOrthodoxy"
    case ultimatumOfTheScream = "UltimatumOfTheScream"
    case ultimatumOfSurvival = "UltimatumOfSurvival"
    case ultimatumOfUltimatums = "UltimatumOfUltimatums"
    case ultimatumOfExile = "UltimatumOfExile"
    case ultimatumOfTheSpiral = "UltimatumOfTheSpiral"
    case ultimatumOfMalevolence = "UltimatumOfMalevolence"
}

/// `CreateGameRequest.asIfRuling`'s chapter-ruling override. A closed, validated enum: this
/// is a request-side field, and the exact backend build this client targets only accepts
/// these 4 values (the schema's own `null` enum member is represented at the
/// `OptionalField<AsIfRuling>` layer, not here).
enum AsIfRuling: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case chapter1
    case chapter2
    case chapter1AsIfRuling = "Chapter1AsIfRuling"
    case chapter2AsIfRuling = "Chapter2AsIfRuling"
}

/// The error thrown when encoding a ``CampaignOption`` whose tag this client build never
/// recognized.
enum CampaignOptionError: Error, Equatable, Sendable {
    case cannotEncodeUnknownTag(String)
}

/// One entry of `CreateGameRequest.options`.
///
/// Decoding discriminates against ``CampaignOptionFlag``'s closed set of known flag tags
/// (rather than relying on ``OpenStringEnum``'s inherent permissiveness), so a genuinely
/// unrecognized tag becomes ``unknown(tag:rawObject:)`` and can never be accidentally
/// treated as, or resubmitted as, a known flag or variant.
enum CampaignOption: Sendable {
    /// A no-content campaign option flag.
    case flag(CampaignOptionFlag)
    /// A named campaign variant, for example `"return-to"`.
    case campaignVariant(String)
    /// A tag not recognized by this client build. Preserves the complete raw wire object
    /// (tag, contents presence/absence/null-ness, and any additive keys) for inspection;
    /// never encodable, since resubmitting an option this client doesn't understand as if
    /// it were a known action is unsafe by construction.
    case unknown(tag: String, rawObject: JSONValue)
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
        } else if let flag = CampaignOptionFlag(rawValue: tag) {
            self = .flag(flag)
        } else {
            self = try .unknown(tag: tag, rawObject: JSONValue(from: decoder))
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
        case let .unknown(tag, _):
            throw CampaignOptionError.cannotEncodeUnknownTag(tag)
        }
    }
}
