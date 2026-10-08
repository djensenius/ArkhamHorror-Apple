import Foundation

struct LaidToRestSpiritDeckPromptPresentation: Sendable, Equatable {
    static let key = "laidToRest.buildSpiritDeck"

    struct Entry: Identifiable, Sendable, Equatable {
        let id: Int
        let code: String?
        let displayName: String?
        let isFixed: Bool

        var isSelectable: Bool {
            code != nil && !isFixed
        }
    }

    let entries: [Entry]
    let fixedEntries: [Entry]
    let count: Int

    var selectableCodes: [String] {
        entries.compactMap { entry in
            guard entry.isSelectable, let code = entry.code else { return nil }
            return code
        }
    }

    var rawStringEntryCodes: [String] {
        entries.compactMap(\.code)
    }

    var distinctRawStringEntryCodes: Set<String> {
        Set(rawStringEntryCodes)
    }

    var displayEntries: [Entry] {
        entries + fixedEntries
    }

    func displayEntries(matching searchText: String) -> [Entry] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return displayEntries }
        return displayEntries.filter { entry in
            entry.code?.lowercased().contains(term) == true
                || entry.displayName?.lowercased().contains(term) == true
        }
    }

    func selectedCount(_ selectedCodes: [String]) -> Int {
        Set(selectedCodes).count
    }

    func canToggle(entryAt index: Int) -> Bool {
        entries.indices.contains(index) && entries[index].isSelectable
    }

    func toggledSelection(_ selectedCodes: [String], entryAt index: Int) -> [String]? {
        guard canToggle(entryAt: index), let code = entries[index].code else { return nil }
        var selected = selectedCodes.filter { distinctRawStringEntryCodes.contains($0) }
        if selected.contains(code) {
            selected.removeAll { $0 == code }
        } else if Set(selected).count < count {
            selected.append(code)
        } else {
            return selected
        }
        return selected
    }

    func canConfirm(_ selectedCodes: [String]) -> Bool {
        supportsSelection(selectedCodes)
    }

    func answer(selectedCodes: [String]) -> JSONValue? {
        guard supportsSelection(selectedCodes) else { return nil }
        return .array([
            .string(Self.key),
            .object(["cardCodes": .array(selectedCodes.map(JSONValue.string))]),
        ])
    }

    func supportsSubmission(_ contents: JSONValue) -> Bool {
        guard case let .array(answerContents) = contents,
              answerContents.count == 2,
              answerContents[0] == .string(Self.key),
              case let .object(payload) = answerContents[1],
              Set(payload.keys) == ["cardCodes"],
              case let .array(cardCodeValues)? = payload["cardCodes"]
        else { return false }
        var selectedCodes: [String] = []
        for value in cardCodeValues {
            guard case let .string(code) = value else { return false }
            selectedCodes.append(code)
        }
        return supportsSelection(selectedCodes)
    }

    private func supportsSelection(_ selectedCodes: [String]) -> Bool {
        guard selectedCodes.count == count,
              Set(selectedCodes).count == count
        else { return false }
        return selectedCodes.allSatisfy { distinctRawStringEntryCodes.contains($0) }
    }
}

extension LaidToRestSpiritDeckPromptPresentation {
    static func make(
        rawQuestion: JSONValue,
        presentation: QuestionPresentation,
        cardCatalog: CardCatalogSnapshot?
    ) -> Self? {
        guard presentation.questionKind == .pickScenarioSpecific,
              case let .object(tagObject) = rawQuestion,
              tagObject["tag"] == .string("PickScenarioSpecific"),
              presentation.key == Self.key,
              let rawPayload = payload(in: rawQuestion),
              let count = positiveInteger(rawPayload["count"]),
              case let .array(cardCodeValues)? = rawPayload["cardCodes"],
              count > 0
        else { return nil }

        let entries = cardCodeValues.enumerated().map { index, value in
            entry(index: index, value: value, isFixed: false, cardCatalog: cardCatalog)
        }
        let validDistinctCodes = Set(entries.compactMap(\.code))
        guard count <= validDistinctCodes.count else { return nil }

        let fixedEntries: [Entry] = if case let .array(fixedValues)? = rawPayload["fixed"] {
            fixedValues.enumerated().map { index, value in
                entry(
                    index: cardCodeValues.count + index,
                    value: value,
                    isFixed: true,
                    cardCatalog: cardCatalog
                )
            }
        } else {
            []
        }

        return Self(entries: entries, fixedEntries: fixedEntries, count: count)
    }

    private static func payload(in rawQuestion: JSONValue) -> [String: JSONValue]? {
        guard case let .object(object) = rawQuestion,
              object["tag"] == .string("PickScenarioSpecific"),
              case let .array(contents)? = object["contents"],
              contents.count == 2,
              contents[0] == .string(key),
              case let .object(payload) = contents[1]
        else { return nil }
        return payload
    }

    private static func positiveInteger(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value,
              number.sign == .plus,
              number.exponent.description == "0",
              let count = Int(number.coefficient),
              count > 0
        else { return nil }
        return count
    }

    private static func entry(
        index: Int,
        value: JSONValue,
        isFixed: Bool,
        cardCatalog: CardCatalogSnapshot?
    ) -> Entry {
        guard case let .string(rawCode) = value,
              let code = try? CardCode(rawCode),
              let displayName = cardCatalog?.displayName(for: code)
        else {
            return Entry(id: index, code: stringValue(value), displayName: nil, isFixed: isFixed)
        }
        return Entry(id: index, code: rawCode, displayName: displayName, isFixed: isFixed)
    }

    private static func stringValue(_ value: JSONValue) -> String? {
        guard case let .string(rawCode) = value else { return nil }
        return rawCode
    }
}
