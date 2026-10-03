import Foundation

// swiftlint:disable file_length

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

    func total(for amounts: [String: Int]) -> Int? {
        var total = 0
        for row in rows {
            let result = total.addingReportingOverflow(amounts[row.id] ?? 0)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
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
        let adjusted: Int
        if delta > 0, current < row.minBound {
            adjusted = min(row.maxBound, row.minBound)
        } else if delta < 0, current > row.maxBound {
            adjusted = max(row.minBound, row.maxBound)
        } else {
            let addition = current.addingReportingOverflow(delta)
            guard !addition.overflow else { return normalizedAmounts(amounts) }
            adjusted = addition.partialValue
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

    func guidanceMessage(
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
        guard let total = total(for: amounts), targetSatisfied(total: total) else {
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

    var bounds: ClosedRange<Int>? {
        guard fromInitialAmount >= 0, toInitialAmount >= 0 else { return nil }
        let lower = 0.subtractingReportingOverflow(toInitialAmount)
        guard !lower.overflow, lower.partialValue <= fromInitialAmount else { return nil }
        return lower.partialValue ... fromInitialAmount
    }

    var lowerBound: Int {
        bounds?.lowerBound ?? 1
    }

    var upperBound: Int {
        bounds?.upperBound ?? 0
    }

    func fromCount(for amount: Int) -> Int? {
        let result = fromInitialAmount.subtractingReportingOverflow(amount)
        guard !result.overflow else { return nil }
        return result.partialValue
    }

    func toCount(for amount: Int) -> Int? {
        let result = toInitialAmount.addingReportingOverflow(amount)
        guard !result.overflow else { return nil }
        return result.partialValue
    }

    func canAdjust(amount: Int, delta: Int) -> Bool {
        let result = amount.addingReportingOverflow(delta)
        guard !result.overflow, let bounds, bounds.contains(result.partialValue) else {
            return false
        }
        return fromCount(for: result.partialValue) != nil
            && toCount(for: result.partialValue) != nil
    }

    func adjustedAmount(_ amount: Int, delta: Int) -> Int {
        let result = amount.addingReportingOverflow(delta)
        guard !result.overflow, let bounds else { return amount }
        return min(max(result.partialValue, bounds.lowerBound), bounds.upperBound)
    }
}

extension BasicChoicePromptPresentation {
    // swiftlint:disable:next function_body_length
    func amountPrompt(in _: BoardProjection) -> BasicChoiceAmountPrompt? {
        guard let presentation = semanticPresentation?.presentation,
              canSubmitPromptAnswer
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
                        labelUnavailableReason: amountRowLabelUnavailableReason(
                            key: amountChoicePromptLabelKey(choice.choiceID),
                            labelText: choice.label,
                            upperBound: choice.maxBound
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
                        labelUnavailableReason: amountRowLabelUnavailableReason(
                            key: paymentChoicePromptLabelKey(choice.choiceID),
                            labelText: choice.title.text,
                            upperBound: choice.max
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

    func amountRowLabelUnavailableReason(
        key: String,
        labelText: String?,
        upperBound: Int
    ) -> StoryUnavailableReason? {
        guard upperBound != 0, labelText?.hasPrefix("$") == true else { return nil }
        let resolution = promptLabelResolutions[key]
        if resolution?.title != nil, resolution?.unavailableReason == nil {
            return nil
        }
        return resolution?.unavailableReason ?? .catalog(.notAdvertised)
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
