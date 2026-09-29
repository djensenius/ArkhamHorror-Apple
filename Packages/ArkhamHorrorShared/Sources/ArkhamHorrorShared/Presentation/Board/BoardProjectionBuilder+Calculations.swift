import Foundation

extension BoardProjectionBuilder {
    static func calculationSummary(
        in value: JSONValue?, playerCount: Int
    ) -> BoardCalculationSummary? {
        if let fixed = safeInteger(value) {
            return BoardCalculationSummary(displayValue: "\(fixed)", staticValue: fixed)
        }
        guard case let .object(object)? = value,
              case let .string(tag)? = object["tag"]
        else { return nil }
        if tag == "Fixed", let fixed = safeInteger(object["contents"]) {
            return BoardCalculationSummary(displayValue: "\(fixed)", staticValue: fixed)
        }
        guard tag == "GameValueCalculation",
              case let .object(contents)? = object["contents"],
              case let .string(innerTag)? = contents["tag"]
        else { return BoardCalculationSummary(displayValue: "?", staticValue: nil) }
        if let resolved = resolvedGameValue(contents, tag: innerTag, playerCount: playerCount) {
            return BoardCalculationSummary(displayValue: "\(resolved)", staticValue: resolved)
        }
        if innerTag == "ValueX" {
            return BoardCalculationSummary(displayValue: "X", staticValue: nil)
        }
        if innerTag == "ValueStar" {
            return BoardCalculationSummary(displayValue: "–", staticValue: nil)
        }
        return BoardCalculationSummary(displayValue: "?", staticValue: nil)
    }

    private static func resolvedGameValue(
        _ object: [String: JSONValue], tag: String, playerCount: Int
    ) -> Int? {
        switch tag {
        case "Static":
            return safeInteger(object["contents"])
        case "PerPlayer":
            return safeInteger(object["contents"]).map { $0 * playerCount }
        case "StaticWithPerPlayer":
            guard let values = fixedIntegerArray(object["contents"], count: 2) else { return nil }
            return values[0] + values[1] * playerCount
        case "ByPlayerCount":
            guard let values = fixedIntegerArray(object["contents"], count: 4) else { return nil }
            let index = min(max(playerCount, 1), 4) - 1
            return values[index]
        default:
            return nil
        }
    }

    private static func fixedIntegerArray(_ value: JSONValue?, count: Int) -> [Int]? {
        guard case let .array(values)? = value, values.count == count else { return nil }
        let result = values.compactMap(safeInteger)
        return result.count == count ? result : nil
    }
}
