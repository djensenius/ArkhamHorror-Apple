/// Phantom tag distinguishing ``ChaosTokenFace``.
enum ChaosTokenFaceTag: Sendable {}
/// A chaos token face. An open string set, not a closed enum: the base game faces
/// (`PlusOne`, `Zero`, `MinusOne`..`MinusEight`, `Skull`, `Cultist`, `Tablet`,
/// `ElderThing`, `AutoFail`, `ElderSign`, `CurseToken`, `BlessToken`, `FrostToken`,
/// `BloodToken`) plus arbitrary homebrew/custom token slugs (for example
/// `:circus-ex-mortis:moon`). Shared by `ChaosToken.chaosTokenFace` and
/// `ChaosBag.forceDraw`.
typealias ChaosTokenFace = OpenStringEnum<ChaosTokenFaceTag>

extension ChaosTokenFace {
    static let plusOne = ChaosTokenFace("PlusOne")
    static let zero = ChaosTokenFace("Zero")
    static let minusOne = ChaosTokenFace("MinusOne")
    static let minusTwo = ChaosTokenFace("MinusTwo")
    static let minusThree = ChaosTokenFace("MinusThree")
    static let minusFour = ChaosTokenFace("MinusFour")
    static let minusFive = ChaosTokenFace("MinusFive")
    static let minusSix = ChaosTokenFace("MinusSix")
    static let minusSeven = ChaosTokenFace("MinusSeven")
    static let minusEight = ChaosTokenFace("MinusEight")
    static let skull = ChaosTokenFace("Skull")
    static let cultist = ChaosTokenFace("Cultist")
    static let tablet = ChaosTokenFace("Tablet")
    static let elderThing = ChaosTokenFace("ElderThing")
    static let autoFail = ChaosTokenFace("AutoFail")
    static let elderSign = ChaosTokenFace("ElderSign")
    static let curseToken = ChaosTokenFace("CurseToken")
    static let blessToken = ChaosTokenFace("BlessToken")
    static let frostToken = ChaosTokenFace("FrostToken")
    static let bloodToken = ChaosTokenFace("BloodToken")
}

/// A single physical chaos token instance (`Arkham.ChaosToken.Types.ChaosToken`).
struct ChaosToken: Sendable {
    let chaosTokenID: ChaosTokenID
    let chaosTokenFace: ChaosTokenFace
    /// `Maybe InvestigatorId` (`CardCode`-backed) of the investigator this token was drawn
    /// for, if any.
    let chaosTokenRevealedBy: InvestigatorID?
    let chaosTokenCancelled: Bool
    let chaosTokenSealed: Bool
}

extension ChaosToken: Equatable, Hashable {}

extension ChaosToken: Codable {
    private enum CodingKeys: String, CodingKey {
        case chaosTokenID = "chaosTokenId"
        case chaosTokenFace
        case chaosTokenRevealedBy
        case chaosTokenCancelled
        case chaosTokenSealed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chaosTokenID = try container.decode(ChaosTokenID.self, forKey: .chaosTokenID)
        chaosTokenFace = try container.decode(ChaosTokenFace.self, forKey: .chaosTokenFace)
        chaosTokenRevealedBy = try decodeRequiredNullable(
            InvestigatorID.self,
            from: container,
            forKey: .chaosTokenRevealedBy,
            codingPath: decoder.codingPath + [CodingKeys.chaosTokenRevealedBy]
        )
        chaosTokenCancelled = try container.decode(Bool.self, forKey: .chaosTokenCancelled)
        chaosTokenSealed = try container.decode(Bool.self, forKey: .chaosTokenSealed)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chaosTokenID, forKey: .chaosTokenID)
        try container.encode(chaosTokenFace, forKey: .chaosTokenFace)
        try container.encode(chaosTokenRevealedBy, forKey: .chaosTokenRevealedBy)
        try container.encode(chaosTokenCancelled, forKey: .chaosTokenCancelled)
        try container.encode(chaosTokenSealed, forKey: .chaosTokenSealed)
    }
}

/// The scenario's chaos bag (`Arkham.ChaosBag.Base.ChaosBag`).
struct ChaosBag: Sendable {
    let chaosTokens: [ChaosToken]
    let setAsideChaosTokens: [ChaosToken]
    let revealedChaosTokens: [ChaosToken]
    /// The in-progress chaos-bag draw/resolution step, if any
    /// (`Arkham.ChaosBagStepState`). Broad and out of scope for this contract slice.
    let choice: JSONValue?
    /// A forced ``ChaosTokenFace``, when set.
    let forceDraw: ChaosTokenFace?
    let tokenPool: [ChaosToken]
    let totalRevealedChaosTokens: [ChaosToken]
    /// A `Source`-keyed map of pending chaos-token requests, encoded as an array of
    /// `[source, chaosTokens]` pairs because `Source` is not a plain string key. Broad
    /// and out of scope for this contract slice.
    let pendingRequests: [JSONValue]
}

extension ChaosBag: Equatable, Hashable {}

extension ChaosBag: Codable {
    private enum CodingKeys: String, CodingKey {
        case chaosTokens
        case setAsideChaosTokens
        case revealedChaosTokens
        case choice
        case forceDraw
        case tokenPool
        case totalRevealedChaosTokens
        case pendingRequests
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chaosTokens = try container.decode([ChaosToken].self, forKey: .chaosTokens)
        setAsideChaosTokens = try container.decode(
            [ChaosToken].self,
            forKey: .setAsideChaosTokens
        )
        revealedChaosTokens = try container.decode([ChaosToken].self, forKey: .revealedChaosTokens)
        choice = try decodeRequiredNullable(
            JSONValue.self,
            from: container,
            forKey: .choice,
            codingPath: decoder.codingPath + [CodingKeys.choice]
        )
        forceDraw = try decodeRequiredNullable(
            ChaosTokenFace.self,
            from: container,
            forKey: .forceDraw,
            codingPath: decoder.codingPath + [CodingKeys.forceDraw]
        )
        tokenPool = try container.decode([ChaosToken].self, forKey: .tokenPool)
        totalRevealedChaosTokens = try container.decode(
            [ChaosToken].self,
            forKey: .totalRevealedChaosTokens
        )
        pendingRequests = try container.decode([JSONValue].self, forKey: .pendingRequests)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chaosTokens, forKey: .chaosTokens)
        try container.encode(setAsideChaosTokens, forKey: .setAsideChaosTokens)
        try container.encode(revealedChaosTokens, forKey: .revealedChaosTokens)
        try container.encode(choice, forKey: .choice)
        try container.encode(forceDraw, forKey: .forceDraw)
        try container.encode(tokenPool, forKey: .tokenPool)
        try container.encode(totalRevealedChaosTokens, forKey: .totalRevealedChaosTokens)
        try container.encode(pendingRequests, forKey: .pendingRequests)
    }
}
