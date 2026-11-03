/// Phantom tag distinguishing ``GameOutcomeResult``.
enum GameOutcomeResultTag: Sendable {}
/// `GameOutcome.result`: `Won` or `Lost`. Open, so a future verdict still decodes.
typealias GameOutcomeResult = OpenStringEnum<GameOutcomeResultTag>

extension GameOutcomeResult {
    static let won = GameOutcomeResult("Won")
    static let lost = GameOutcomeResult("Lost")
}

/// Phantom tag distinguishing ``GameOutcomeCertainty``.
enum GameOutcomeCertaintyTag: Sendable {}
/// `GameOutcome.certainty`: `Certain` or `Uncertain`.
typealias GameOutcomeCertainty = OpenStringEnum<GameOutcomeCertaintyTag>

extension GameOutcomeCertainty {
    static let certain = GameOutcomeCertainty("Certain")
    static let uncertain = GameOutcomeCertainty("Uncertain")
}

/// Phantom tag distinguishing ``GameOutcomeSource``.
enum GameOutcomeSourceTag: Sendable {}
/// `GameOutcome.source`: `Recorded` verdicts were declared by the ending itself;
/// `Inferred` ones were reconstructed afterwards and can be wrong.
typealias GameOutcomeSource = OpenStringEnum<GameOutcomeSourceTag>

extension GameOutcomeSource {
    static let recorded = GameOutcomeSource("Recorded")
    static let inferred = GameOutcomeSource("Inferred")
}

/// How a finished game ended (`Arkham.Game.Outcome.GameOutcome`, schema 0.1.57). Shared by
/// the game list's `GameDetails.outcome` and `PublicGame.outcome`.
struct GameOutcome: Sendable, Equatable, Hashable {
    let result: GameOutcomeResult
    let certainty: GameOutcomeCertainty
    /// An i18n key for the clause the Campaign Guide attaches to the verdict, if any.
    let note: String?
    let ending: GameOutcomeEnding?
    let source: GameOutcomeSource
}

extension GameOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case result
        case certainty
        case note
        case ending
        case source
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decode(GameOutcomeResult.self, forKey: .result)
        certainty = try container.decode(GameOutcomeCertainty.self, forKey: .certainty)
        note = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .note,
            codingPath: decoder.codingPath + [CodingKeys.note]
        )
        ending = try decodeRequiredNullable(
            GameOutcomeEnding.self,
            from: container,
            forKey: .ending,
            codingPath: decoder.codingPath + [CodingKeys.ending]
        )
        source = try container.decode(GameOutcomeSource.self, forKey: .source)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(result, forKey: .result)
        try container.encode(certainty, forKey: .certainty)
        try container.encode(note, forKey: .note)
        try container.encode(ending, forKey: .ending)
        try container.encode(source, forKey: .source)
    }
}

/// `GameOutcome.ending`: the scenario and resolution the verdict was reached in.
struct GameOutcomeEnding: Sendable, Equatable, Hashable, Codable {
    let scenario: String
    let resolution: GameOutcomeResolution
}

/// `GameOutcome.ending.resolution`: `{"tag":"NoResolution"}` or
/// `{"tag":"Resolution","contents":n}`.
enum GameOutcomeResolution: Sendable, Equatable, Hashable {
    case noResolution
    case resolution(Int)
}

extension GameOutcomeResolution: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "NoResolution":
            self = .noResolution
        case "Resolution":
            self = try .resolution(container.decode(Int.self, forKey: .contents))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .tag,
                in: container,
                debugDescription: "Unknown game outcome resolution tag \"\(tag)\""
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noResolution:
            try container.encode("NoResolution", forKey: .tag)
        case let .resolution(number):
            try container.encode("Resolution", forKey: .tag)
            try container.encode(number, forKey: .contents)
        }
    }
}
