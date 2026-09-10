import Foundation

enum BoardSkillTestStep: String, Sendable, Equatable {
    case determineSkill = "DetermineSkillOfTestStep"
    case firstPlayerWindow = "SkillTestFastWindow1"
    case commitCards = "CommitCardsFromHandToSkillTestStep"
    case secondPlayerWindow = "SkillTestFastWindow2"
    case revealChaosToken = "RevealChaosTokenStep"
    case resolveChaosSymbol = "ResolveChaosSymbolEffectsStep"
    case determineModifiedValue = "DetermineInvestigatorsModifiedSkillValueStep"
    case determineResult = "DetermineSuccessOrFailureOfSkillTestStep"
    case applyResults = "ApplySkillTestResultsStep"
    case end = "SkillTestEndsStep"

    var displayTitle: String {
        switch self {
        case .determineSkill: "Determine skill"
        case .firstPlayerWindow, .secondPlayerWindow: "Player window"
        case .commitCards: "Commit cards"
        case .revealChaosToken: "Reveal chaos token"
        case .resolveChaosSymbol: "Resolve chaos symbol"
        case .determineModifiedValue: "Determine modified skill"
        case .determineResult: "Determine result"
        case .applyResults: "Apply results"
        case .end: "End skill test"
        }
    }
}

struct BoardSkillTestResult: Sendable, Equatable {
    let skillValue: Int
    let iconValue: Int
    let chaosTokensValue: Int
    let difficulty: Int
    let resultModifiers: Int?
    let succeeded: Bool
}

struct BoardSkillTestSummary: Sendable, Equatable {
    let investigatorID: InvestigatorID
    let step: BoardSkillTestStep
    let modifiedSkillValue: Int
    let modifiedDifficulty: Int
    let result: BoardSkillTestResult?
}

enum BoardSkillTestProjection: Sendable, Equatable {
    case available(BoardSkillTestSummary)
    case unavailable
}

/// Extracts only the backend's current skill-test display values. This deliberately has
/// no arithmetic or rules logic: `succeeded` comes directly from
/// `skillTestResultsSuccess`, and any unknown required shape becomes `.unavailable`.
enum BoardSkillTestProjectionBuilder {
    static func makeProjection(
        skillTest: JSONValue?, results: JSONValue?
    ) -> BoardSkillTestProjection? {
        guard let skillTest else {
            return results == nil ? nil : .unavailable
        }
        guard case let .object(object) = skillTest,
              case let .string(rawInvestigatorID)? = object["investigator"],
              let investigatorCode = BasicChoiceParser.strictCardCode(rawInvestigatorID),
              case let .string(rawStep)? = object["step"],
              let step = BoardSkillTestStep(rawValue: rawStep),
              let modifiedSkillValue = integer(object["modifiedSkillValue"]),
              let modifiedDifficulty = integer(object["modifiedDifficulty"]),
              let result = parseResult(results)
        else {
            return .unavailable
        }
        return .available(BoardSkillTestSummary(
            investigatorID: InvestigatorID(investigatorCode),
            step: step,
            modifiedSkillValue: modifiedSkillValue,
            modifiedDifficulty: modifiedDifficulty,
            result: result
        ))
    }

    private static func parseResult(_ value: JSONValue?) -> BoardSkillTestResult?? {
        guard let value else { return .some(nil) }
        guard case let .object(object) = value,
              let skillValue = integer(object["skillTestResultsSkillValue"]),
              let iconValue = integer(object["skillTestResultsIconValue"]),
              let chaosTokensValue = integer(object["skillTestResultsChaosTokensValue"]),
              let difficulty = integer(object["skillTestResultsDifficulty"]),
              let resultModifiers = nullableInteger(
                  object["skillTestResultsResultModifiers"]
              ),
              case let .bool(succeeded)? = object["skillTestResultsSuccess"]
        else {
            return nil
        }
        return .some(BoardSkillTestResult(
            skillValue: skillValue,
            iconValue: iconValue,
            chaosTokensValue: chaosTokensValue,
            difficulty: difficulty,
            resultModifiers: resultModifiers,
            succeeded: succeeded
        ))
    }

    private static func nullableInteger(_ value: JSONValue?) -> Int?? {
        guard let value else { return nil }
        if value == .null {
            return .some(nil)
        }
        guard let integer = integer(value) else { return nil }
        return .some(integer)
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value,
              number.exponent.isZero,
              let magnitude = Int(number.coefficient)
        else { return nil }
        return number.sign == .minus ? -magnitude : magnitude
    }
}
