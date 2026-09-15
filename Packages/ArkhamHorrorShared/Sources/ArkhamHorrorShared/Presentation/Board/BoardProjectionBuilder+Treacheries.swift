import Foundation

extension BoardProjectionBuilder {
    static func makeTreacheryNodes(
        from treacheries: UUIDEntityMap<TreacheryIDTag>
    ) -> [TreacheryID: BoardTreacheryNode] {
        var result: [TreacheryID: BoardTreacheryNode] = [:]
        for (mapID, rawValue) in treacheries {
            guard case let .object(object) = rawValue,
                  case let .string(rawID)? = object["id"],
                  let embeddedID = TreacheryID(codingKey: AnyCodingKey(stringValue: rawID)),
                  embeddedID == mapID,
                  case let .string(rawCardCode)? = object["cardCode"],
                  let cardCode = try? CardCode(rawCardCode),
                  let clueCount = clueCount(in: object["tokens"])
            else { continue }
            result[mapID] = BoardTreacheryNode(
                id: mapID,
                cardCode: cardCode,
                clueCount: clueCount
            )
        }
        return result
    }

    private static func clueCount(in value: JSONValue?) -> Int? {
        guard case let .array(tokens)? = value else { return nil }
        var total = 0
        for token in tokens {
            guard case let .array(contents) = token,
                  contents.count == 2,
                  case let .string(name) = contents[0],
                  let count = canonicalNonNegativeInteger(contents[1])
            else { return nil }
            if name == "Clue" {
                let addition = total.addingReportingOverflow(count)
                guard !addition.overflow else { return nil }
                total = addition.partialValue
            }
        }
        return total
    }

    private static func canonicalNonNegativeInteger(_ value: JSONValue) -> Int? {
        guard case let .number(number) = value,
              number.sign == .plus,
              let token = number.rawToken,
              !token.isEmpty,
              token.allSatisfy(\.isASCIIWholeNumber),
              token == "0" || token.first != "0"
        else { return nil }
        return Int(token)
    }
}
