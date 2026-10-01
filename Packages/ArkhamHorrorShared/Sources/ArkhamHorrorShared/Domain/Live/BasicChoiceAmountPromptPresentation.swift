import Foundation

struct BasicChoiceAmountPrompt: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case amounts
        case payment
    }

    let kind: Kind
    let legend: String
    let rows: [BasicChoiceAmountPromptRow]
    let target: QuestionPresentation.AmountTarget?

    var visibleRows: [BasicChoiceAmountPromptRow] {
        rows.filter(\.isVisible)
    }

    var initialAmounts: [String: Int] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.id, 0) })
    }

    func normalizedAmounts(_ amounts: [String: Int]) -> [String: Int] {
        var result = initialAmounts
        for row in rows {
            if let amount = amounts[row.id] {
                result[row.id] = amount
            }
        }
        return result
    }

    func total(for amounts: [String: Int]) -> Int {
        rows.reduce(0) { partial, row in
            partial + (amounts[row.id] ?? 0)
        }
    }

    func row(id: String) -> BasicChoiceAmountPromptRow? {
        rows.first { $0.id == id }
    }

    func adjustedAmounts(
        _ amounts: [String: Int], rowID: String, delta: Int
    ) -> [String: Int] {
        guard let row = row(id: rowID), row.isVisible else { return normalizedAmounts(amounts) }
        var result = normalizedAmounts(amounts)
        let current = result[rowID] ?? 0
        let adjusted: Int = if delta > 0, current < row.minBound {
            min(row.maxBound, row.minBound)
        } else if delta < 0, current > row.maxBound {
            max(row.minBound, row.maxBound)
        } else {
            current + delta
        }
        result[rowID] = min(max(adjusted, row.minBound), row.maxBound)
        return result
    }

    func canAdjust(_ amounts: [String: Int], rowID: String, delta: Int) -> Bool {
        guard let row = row(id: rowID), row.isVisible else { return false }
        let current = amounts[rowID] ?? 0
        if delta > 0 {
            return current < row.maxBound
        }
        if delta < 0 {
            return current > row.minBound
        }
        return false
    }

    func isLegal(_ amounts: [String: Int]) -> Bool {
        guard visibleRows.allSatisfy(\.isLabelResolved) else { return false }
        let choiceIDs = Set(rows.map(\.id))
        guard choiceIDs.count == rows.count,
              Set(amounts.keys) == choiceIDs
        else { return false }
        for row in rows {
            guard row.minBound <= row.maxBound,
                  let amount = amounts[row.id],
                  amount >= row.minBound,
                  amount <= row.maxBound
            else { return false }
        }
        return targetSatisfied(total: total(for: amounts))
    }

    func targetHint(in presentation: BasicChoicePromptPresentation) -> String {
        switch target {
        case nil:
            presentation.semanticLocalized(
                "amountPrompt.target.any",
                value: "Choose any amount"
            )
        case let .min(minimum):
            presentation.semanticLocalized(
                "amountPrompt.target.min",
                value: "Choose at least \(minimum)",
                arguments: [Int64(minimum)]
            )
        case let .max(maximum):
            presentation.semanticLocalized(
                "amountPrompt.target.max",
                value: "Choose at most \(maximum)",
                arguments: [Int64(maximum)]
            )
        case let .total(required):
            presentation.semanticLocalized(
                "amountPrompt.target.total",
                value: "Choose exactly \(required)",
                arguments: [Int64(required)]
            )
        case let .oneOf(allowed):
            presentation.semanticLocalized(
                "amountPrompt.target.oneOf",
                value: "Choose one of \(Self.joinedNumbers(allowed))",
                arguments: [Self.joinedNumbers(allowed)]
            )
        }
    }

    func disabledReason(
        for amounts: [String: Int], in presentation: BasicChoicePromptPresentation
    ) -> String? {
        if let unresolvedReason = visibleRows.first(where: { !$0.isLabelResolved }) {
            return presentation.semanticLocalized(
                "amountPrompt.disabled.labels",
                value: "The text for \(unresolvedReason.title) is not currently available.",
                arguments: [unresolvedReason.title]
            )
        }
        if !hasExactChoiceKeys(amounts) {
            return presentation.semanticLocalized(
                "amountPrompt.disabled.incomplete",
                value: "Every amount row needs a value."
            )
        }
        if !rowsSatisfyBounds(amounts) {
            return presentation.semanticLocalized(
                "amountPrompt.disabled.bounds",
                value: "Keep each amount within its allowed range."
            )
        }
        if !targetSatisfied(total: total(for: amounts)) {
            return targetHint(in: presentation)
        }
        return nil
    }

    private func hasExactChoiceKeys(_ amounts: [String: Int]) -> Bool {
        let choiceIDs = Set(rows.map(\.id))
        return choiceIDs.count == rows.count && Set(amounts.keys) == choiceIDs
    }

    private func rowsSatisfyBounds(_ amounts: [String: Int]) -> Bool {
        for row in rows {
            guard row.minBound <= row.maxBound,
                  let amount = amounts[row.id],
                  amount >= row.minBound,
                  amount <= row.maxBound
            else { return false }
        }
        return true
    }

    private func targetSatisfied(total: Int) -> Bool {
        switch target {
        case nil:
            true
        case let .min(minimum):
            total >= minimum
        case let .max(maximum):
            total <= maximum
        case let .total(required):
            total == required
        case let .oneOf(allowed):
            allowed.contains(total)
        }
    }

    private static func joinedNumbers(_ values: [Int]) -> String {
        values.map(String.init).joined(separator: ", ")
    }
}

struct BasicChoiceAmountPromptRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let minBound: Int
    let maxBound: Int
    let labelUnavailableReason: StoryUnavailableReason?

    var isVisible: Bool {
        maxBound != 0
    }

    var isLabelResolved: Bool {
        labelUnavailableReason == nil
    }
}

struct BasicChoiceExchangePrompt: Sendable, Equatable {
    let fromInvestigator: String
    let fromDisplayName: String
    let fromInitialAmount: Int
    let toInvestigator: String
    let toDisplayName: String
    let toInitialAmount: Int
    let token: String

    var lowerBound: Int {
        -toInitialAmount
    }

    var upperBound: Int {
        fromInitialAmount
    }

    func fromCount(for amount: Int) -> Int {
        fromInitialAmount - amount
    }

    func toCount(for amount: Int) -> Int {
        toInitialAmount + amount
    }

    func isLegal(_ amount: Int) -> Bool {
        fromInitialAmount >= 0 && toInitialAmount >= 0
            && lowerBound <= upperBound && amount >= lowerBound && amount <= upperBound
    }

    func canAdjust(amount: Int, delta: Int) -> Bool {
        isLegal(amount + delta)
    }

    func adjustedAmount(_ amount: Int, delta: Int) -> Int {
        min(max(amount + delta, lowerBound), upperBound)
    }
}

extension BasicChoicePromptPresentation {
    // swiftlint:disable:next function_body_length
    func amountPrompt(in _: BoardProjection) -> BasicChoiceAmountPrompt? {
        guard let presentation = semanticPresentation?.presentation,
              canSubmitPromptAnswer,
              Self.supportsSemanticPrompt(
                  rawQuestion: identity.rawQuestion,
                  presentation: presentation
              )
        else { return nil }
        switch presentation.answer {
        case .amounts:
            guard let choices = presentation.amountChoices else { return nil }
            return BasicChoiceAmountPrompt(
                kind: .amounts,
                legend: promptLabel(
                    key: "label",
                    label: presentation.label,
                    fallback: semanticLocalized(
                        "amountPrompt.legend.amounts",
                        value: "Choose amounts"
                    )
                ),
                rows: choices.enumerated().map { index, choice in
                    BasicChoiceAmountPromptRow(
                        id: choice.choiceID,
                        title: promptLabel(
                            key: amountChoicePromptLabelKey(choice.choiceID),
                            labelText: choice.label,
                            fallback: semanticLocalized(
                                "amountPrompt.row.fallback",
                                value: "Choice \(index + 1)",
                                arguments: [Int64(index + 1)]
                            )
                        ),
                        minBound: choice.minBound,
                        maxBound: choice.maxBound,
                        labelUnavailableReason: promptLabelUnavailableReason(
                            key: amountChoicePromptLabelKey(choice.choiceID),
                            labelText: choice.label
                        )
                    )
                },
                target: presentation.target
            )
        case .paymentAmounts:
            guard let choices = presentation.paymentChoices else { return nil }
            return BasicChoiceAmountPrompt(
                kind: .payment,
                legend: promptLabel(
                    key: "label",
                    label: presentation.label,
                    fallback: semanticLocalized(
                        "amountPrompt.legend.payment",
                        value: "Choose payment amounts"
                    )
                ),
                rows: choices.enumerated().map { index, choice in
                    BasicChoiceAmountPromptRow(
                        id: choice.choiceID,
                        title: promptLabel(
                            key: paymentChoicePromptLabelKey(choice.choiceID),
                            label: choice.title,
                            fallback: semanticLocalized(
                                "amountPrompt.row.fallback",
                                value: "Choice \(index + 1)",
                                arguments: [Int64(index + 1)]
                            )
                        ),
                        minBound: choice.min,
                        maxBound: choice.max,
                        labelUnavailableReason: promptLabelUnavailableReason(
                            key: paymentChoicePromptLabelKey(choice.choiceID),
                            labelText: choice.title.text
                        )
                    )
                },
                target: presentation.target
            )
        case .singleChoice, .exchangeAmounts, .deck, .standaloneSettings, .campaignSettings,
             .pickDestiny, .campaignSpecific, .scenarioSpecific, .continueCampaign:
            return nil
        }
    }

    func exchangePrompt(in projection: BoardProjection) -> BasicChoiceExchangePrompt? {
        guard let presentation = semanticPresentation?.presentation,
              case .exchangeAmounts = presentation.answer,
              canSubmitPromptAnswer,
              Self.supportsSemanticPrompt(
                  rawQuestion: identity.rawQuestion,
                  presentation: presentation
              ),
              let fromInvestigator = presentation.fromInvestigator,
              let fromInitialAmount = presentation.fromInitialAmount,
              let toInvestigator = presentation.toInvestigator,
              let toInitialAmount = presentation.toInitialAmount,
              let token = presentation.token,
              presentation.source != nil
        else { return nil }
        return BasicChoiceExchangePrompt(
            fromInvestigator: fromInvestigator,
            fromDisplayName: investigatorName(fromInvestigator, in: projection),
            fromInitialAmount: fromInitialAmount,
            toInvestigator: toInvestigator,
            toDisplayName: investigatorName(toInvestigator, in: projection),
            toInitialAmount: toInitialAmount,
            token: token
        )
    }

    func amountChoicePromptLabelKey(_ choiceID: String) -> String {
        "amountChoice.\(choiceID)"
    }

    func paymentChoicePromptLabelKey(_ choiceID: String) -> String {
        "paymentChoice.\(choiceID)"
    }

    private func promptLabel(
        key: String,
        label: QuestionPresentation.Label?,
        fallback: String
    ) -> String {
        promptLabel(key: key, labelText: label?.text, fallback: fallback)
    }

    private func promptLabelUnavailableReason(
        key: String,
        labelText: String?
    ) -> StoryUnavailableReason? {
        guard labelText?.hasPrefix("$") == true else { return nil }
        if promptLabelResolutions[key]?.title != nil {
            return nil
        }
        return promptLabelResolutions[key]?.unavailableReason ?? .catalog(.notAdvertised)
    }

    private func promptLabel(
        key: String,
        labelText: String?,
        fallback: String
    ) -> String {
        if let title = promptLabelResolutions[key]?.title {
            return title
        }
        guard let labelText else { return fallback }
        if labelText.hasPrefix("$") {
            return fallback
        }
        let trimmed = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func investigatorName(_ rawID: String, in projection: BoardProjection) -> String {
        guard let cardCode = try? CardCode(rawID) else { return rawID }
        let id = InvestigatorID(cardCode)
        return projection.investigators.first { $0.id == id }?.displayName
            ?? cardCatalog?.displayName(for: cardCode)
            ?? rawID
    }
}
