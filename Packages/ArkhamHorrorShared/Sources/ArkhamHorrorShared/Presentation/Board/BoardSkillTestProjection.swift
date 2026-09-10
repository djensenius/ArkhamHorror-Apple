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

struct BoardSkillTestVerdict: Sendable, Equatable {
    let succeeded: Bool
    let amount: Int
    let automatic: Bool

    var displayLabel: String {
        let result = succeeded ? "Succeeded" : "Failed"
        return automatic
            ? "Automatically \(result.lowercased()) by \(amount)"
            : "\(result) by \(amount)"
    }
}

struct BoardSkillTestSummary: Sendable, Equatable {
    let investigatorID: InvestigatorID
    let step: BoardSkillTestStep
    let modifiedSkillValue: Int
    let modifiedDifficulty: Int
    let verdict: BoardSkillTestVerdict?
    let result: BoardSkillTestResult?
}

enum BoardSkillTestProjection: Sendable, Equatable {
    case available(BoardSkillTestSummary)
    case unavailable
}

/// Extracts only the backend's current skill-test display values. This deliberately has
/// no arithmetic or rules logic: the verdict comes directly from `skillTest.result`,
/// the optional breakdown comes from `skillTestResults`, and any unknown required
/// shape or disagreement between those surfaces becomes `.unavailable`.
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
              let verdict = parseVerdict(object["result"]),
              let result = parseResult(results),
              verdict?.succeeded == result?.succeeded || verdict == nil || result == nil
        else {
            return .unavailable
        }
        return .available(BoardSkillTestSummary(
            investigatorID: InvestigatorID(investigatorCode),
            step: step,
            modifiedSkillValue: modifiedSkillValue,
            modifiedDifficulty: modifiedDifficulty,
            verdict: verdict,
            result: result
        ))
    }

    private static func parseVerdict(_ value: JSONValue?) -> BoardSkillTestVerdict?? {
        guard let value else { return .some(nil) }
        if value == .null {
            return .some(nil)
        }
        guard case let .object(object) = value,
              case let .string(tag)? = object["tag"]
        else { return nil }
        if tag == "Unrun" {
            return object["contents"] == nil ? .some(nil) : nil
        }
        guard tag == "SucceededBy" || tag == "FailedBy",
              case let .array(contents)? = object["contents"],
              contents.count == 2,
              case let .string(resultType) = contents[0],
              resultType == "Automatic" || resultType == "NonAutomatic",
              let amount = integer(contents[1]),
              amount >= 0
        else { return nil }
        return .some(BoardSkillTestVerdict(
            succeeded: tag == "SucceededBy",
            amount: amount,
            automatic: resultType == "Automatic"
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
