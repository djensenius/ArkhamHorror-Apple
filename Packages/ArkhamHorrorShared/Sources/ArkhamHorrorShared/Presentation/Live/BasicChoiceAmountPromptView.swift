import SwiftUI

extension BasicChoicePromptView {
    // swiftlint:disable:next function_body_length
    func amountAllocationPrompt(_ amountPrompt: BasicChoiceAmountPrompt) -> some View {
        let amounts = controller.amountDraft(for: presentation)
        let normalized = amountPrompt.normalizedAmounts(amounts)
        let total = amountPrompt.total(for: normalized)
        let submitEnabled = presentation.canSubmit && amountPrompt.isLegal(normalized)
        let disabledReason = amountPrompt.disabledReason(for: normalized, in: presentation)
        return VStack(alignment: .leading, spacing: 10) {
            Text(amountPrompt.legend)
                .font(.callout.weight(.semibold))
                .accessibilityIdentifier("liveGame.prompt.amount.legend")
            ForEach(Array(amountPrompt.visibleRows.enumerated()), id: \.element.id) { index, row in
                amountRow(row, index: index, amount: normalized[row.id] ?? 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(promptString("amountPrompt.total", value: "Total: %lld", Int64(total)))
                    .font(.footnote.monospacedDigit())
                    .accessibilityIdentifier("liveGame.prompt.amount.total")
                Text(amountPrompt.targetHint(in: presentation))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(submitEnabled ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("liveGame.prompt.amount.targetHint")
                if let disabledReason {
                    Text(disabledReason)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("liveGame.prompt.amount.disabledReason")
                }
            }
            SemanticActionControl(
                accessibilityLabel: Text(promptString("amountPrompt.submit", value: "Submit")),
                semanticFocusID: BoardFocusID.promptAmountSubmit,
                onOutcome: { controller.handle(focusID: $0, $1) },
                label: {
                    HStack {
                        Text(promptString("amountPrompt.submit", value: "Submit"))
                        if presentation.actionPhase == .sending {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            )
            .buttonStyle(.borderedProminent)
            .focused(focusBinding, equals: BoardFocusID.promptAmountSubmit)
            .disabled(!submitEnabled)
            .accessibilityHint(
                disabledReason
                    ?? promptString(
                        "amountPrompt.submit.hint",
                        value: "Sends this allocation with version checking."
                    )
            )
            .accessibilityIdentifier("liveGame.prompt.amount.submit")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveGame.prompt.amount")
    }

    // swiftlint:disable:next function_body_length
    private func amountRow(
        _ row: BasicChoiceAmountPromptRow, index: Int, amount: Int
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body)
                Text(promptString(
                    "amountPrompt.row.bounds",
                    value: "Allowed %1$lld–%2$lld",
                    Int64(row.minBound), Int64(row.maxBound)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            amountControlButton(
                label: "−",
                accessibilityLabel: promptString(
                    "amountPrompt.decrease.accessibility",
                    value: "Decrease %@",
                    row.title
                ),
                focusID: BoardFocusID.promptAmountDecrease(index),
                disabled: !controller.adjustmentAvailable(rowID: row.id, delta: -1)
            )
            Text("\(amount)")
                .font(.headline.monospacedDigit())
                .frame(minWidth: 32)
                .accessibilityHidden(true)
            amountControlButton(
                label: "+",
                accessibilityLabel: promptString(
                    "amountPrompt.increase.accessibility",
                    value: "Increase %@",
                    row.title
                ),
                focusID: BoardFocusID.promptAmountIncrease(index),
                disabled: !controller.adjustmentAvailable(rowID: row.id, delta: 1)
            )
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(promptString(
            "amountPrompt.row.value",
            value: "%lld, allowed %lld to %lld",
            Int64(amount), Int64(row.minBound), Int64(row.maxBound)
        ))
        .accessibilityHint(promptString(
            "amountPrompt.row.hint",
            value: "Swipe up or down to adjust. Left and right controls also change this value."
        ))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                _ = controller.adjustAmount(rowID: row.id, delta: 1)
            case .decrement:
                _ = controller.adjustAmount(rowID: row.id, delta: -1)
            @unknown default:
                break
            }
        }
        .accessibilityIdentifier("liveGame.prompt.amount.row.\(index)")
    }

    private func amountControlButton(
        label: String,
        accessibilityLabel: String,
        focusID: SemanticFocusID,
        disabled: Bool
    ) -> some View {
        SemanticActionControl(
            accessibilityLabel: Text(accessibilityLabel),
            semanticFocusID: focusID,
            onOutcome: { controller.handle(focusID: $0, $1) },
            label: { Text(label).font(.headline.monospacedDigit()) }
        )
        .buttonStyle(.bordered)
        .focused(focusBinding, equals: focusID)
        .disabled(disabled || !presentation.canSubmit)
        .accessibilityIdentifier("liveGame.prompt.amount.control.\(focusID.rawValue)")
    }

    // swiftlint:disable:next function_body_length
    func exchangeAmountPrompt(_ exchangePrompt: BasicChoiceExchangePrompt) -> some View {
        let amount = controller.exchangeAmount(for: presentation)
        let submitEnabled = presentation.canSubmit && exchangePrompt.isLegal(amount)
        let tokenTitle = exchangeTokenTitle(exchangePrompt.token)
        return VStack(alignment: .leading, spacing: 10) {
            Text(promptString(
                "amountPrompt.exchange.legend",
                value: "Exchange %@",
                tokenTitle
            ))
            .font(.callout.weight(.semibold))
            .accessibilityIdentifier("liveGame.prompt.exchange.legend")
            HStack(spacing: 12) {
                exchangeInvestigatorColumn(
                    name: exchangePrompt.fromDisplayName,
                    count: exchangePrompt.fromCount(for: amount)
                )
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        amountControlButton(
                            label: "←",
                            accessibilityLabel: promptString(
                                "amountPrompt.exchange.decrease.accessibility",
                                value: "Move one %@ back to %@",
                                tokenTitle, exchangePrompt.fromDisplayName
                            ),
                            focusID: BoardFocusID.promptExchangeDecrease,
                            disabled: !exchangePrompt.canAdjust(amount: amount, delta: -1)
                        )
                        Text("\(abs(amount))")
                            .font(.headline.monospacedDigit())
                            .accessibilityHidden(true)
                        amountControlButton(
                            label: "→",
                            accessibilityLabel: promptString(
                                "amountPrompt.exchange.increase.accessibility",
                                value: "Move one %@ to %@",
                                tokenTitle, exchangePrompt.toDisplayName
                            ),
                            focusID: BoardFocusID.promptExchangeIncrease,
                            disabled: !exchangePrompt.canAdjust(amount: amount, delta: 1)
                        )
                    }
                    Text(exchangeDirectionText(exchangePrompt, amount: amount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                exchangeInvestigatorColumn(
                    name: exchangePrompt.toDisplayName,
                    count: exchangePrompt.toCount(for: amount)
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(promptString(
                "amountPrompt.exchange.accessibility",
                value: "%1$@ has %2$lld. %3$@ has %4$lld.",
                exchangePrompt.fromDisplayName,
                Int64(exchangePrompt.fromCount(for: amount)),
                exchangePrompt.toDisplayName,
                Int64(exchangePrompt.toCount(for: amount))
            ))
            .accessibilityHint(promptString(
                "amountPrompt.exchange.hint",
                value: "Swipe up or down to move tokens between investigators."
            ))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    _ = controller.adjustExchangeAmount(delta: 1)
                case .decrement:
                    _ = controller.adjustExchangeAmount(delta: -1)
                @unknown default:
                    break
                }
            }
            SemanticActionControl(
                accessibilityLabel: Text(promptString(
                    "amountPrompt.exchange.submit",
                    value: "Exchange"
                )),
                semanticFocusID: BoardFocusID.promptExchangeSubmit,
                onOutcome: { controller.handle(focusID: $0, $1) },
                label: {
                    HStack {
                        Text(promptString("amountPrompt.exchange.submit", value: "Exchange"))
                        if presentation.actionPhase == .sending {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            )
            .buttonStyle(.borderedProminent)
            .focused(focusBinding, equals: BoardFocusID.promptExchangeSubmit)
            .disabled(!submitEnabled)
            .accessibilityHint(promptString(
                "amountPrompt.submit.hint",
                value: "Sends this allocation with version checking."
            ))
            .accessibilityIdentifier("liveGame.prompt.exchange.submit")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveGame.prompt.exchange")
    }

    private func exchangeInvestigatorColumn(name: String, count: Int) -> some View {
        VStack(spacing: 4) {
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text("\(count)")
                .font(.title3.monospacedDigit().weight(.bold))
        }
        .frame(maxWidth: .infinity)
    }

    private func exchangeTokenTitle(_ token: String) -> String {
        switch token {
        case "Resource":
            promptString("amountPrompt.token.resource", value: "resource")
        case "Clue":
            promptString("amountPrompt.token.clue", value: "clue")
        case "Damage":
            promptString("amountPrompt.token.damage", value: "damage")
        case "Horror":
            promptString("amountPrompt.token.horror", value: "horror")
        default:
            token
        }
    }

    private func exchangeDirectionText(
        _ exchangePrompt: BasicChoiceExchangePrompt, amount: Int
    ) -> String {
        if amount == 0 {
            return promptString("amountPrompt.exchange.none", value: "No tokens moved")
        }
        if amount > 0 {
            return promptString(
                "amountPrompt.exchange.forward",
                value: "%1$lld to %2$@",
                Int64(amount), exchangePrompt.toDisplayName
            )
        }
        return promptString(
            "amountPrompt.exchange.backward",
            value: "%1$lld to %2$@",
            Int64(abs(amount)), exchangePrompt.fromDisplayName
        )
    }

    private func promptString(
        _ key: StaticString,
        value: String.LocalizationValue,
        _ arguments: CVarArg...
    ) -> String {
        presentation.semanticLocalized(key, value: value, arguments: arguments)
    }
}
