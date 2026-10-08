import SwiftUI

// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
struct BasicChoicePromptView: View {
    let presentation: BasicChoicePromptPresentation
    let controller: BoardCommandController
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let isCompact: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isStoryPrompt: Bool {
        presentation.isStoryPrompt
    }

    private var revealsPromptOwnerHandCardFaces: Bool {
        presentation.revealsHandCardFaces(
            in: controller.projection,
            localPlayerID: controller.localPlayerID,
            isSolo: controller.isSolo
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        presentation.headerTitle(in: controller.projection),
                        systemImage: isStoryPrompt ? "book.closed.fill" : "questionmark.circle.fill"
                    )
                    .font(.headline)
                    if let subtitle = presentation.headerSubtitle(
                        in: controller.projection,
                        revealsHandCardFaces: revealsPromptOwnerHandCardFaces
                    ) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("Step \(presentation.questionVersion)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let skillTest = controller.projection.skillTest {
                SkillTestSummaryView(projection: skillTest)
            }

            if !presentation.isRenderableQuestion(in: controller.projection) {
                Label("Update required", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if let travelPrompt = presentation.scarletKeysTravelPrompt {
                ScarletKeysTravelPromptView(
                    prompt: travelPrompt,
                    canSubmit: presentation.canSubmit,
                    controller: controller,
                    focusBinding: focusBinding
                )
            } else if let pickDestinyPrompt = presentation.pickDestinyPrompt {
                switch pickDestinyPrompt {
                case let .resolved(prompt):
                    PickDestinyPromptView(
                        prompt: prompt,
                        drawings: controller.pickDestinyDrawings(for: presentation),
                        canSubmit: presentation.canSubmit,
                        controller: controller,
                        focusBinding: focusBinding,
                        isCompact: isCompact
                    )
                    .id(presentation.identity)
                case let .unavailable(reason):
                    Label(
                        pickDestinyUnavailableAnnouncement(for: reason),
                        systemImage: "text.badge.xmark"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("liveGame.prompt.pickDestiny.catalogUnavailable")
                }
            } else if let amountPrompt = presentation.amountPrompt(in: controller.projection) {
                amountAllocationPrompt(amountPrompt)
            } else if let exchangePrompt = presentation.exchangePrompt(in: controller.projection) {
                exchangeAmountPrompt(exchangePrompt)
            } else if presentation.isStandaloneSettingsPrompt(in: controller.projection) {
                standaloneSettingsPrompt
            } else if let spiritDeckPrompt = presentation.laidToRestSpiritDeckPrompt {
                scenarioSpecificPrompt(spiritDeckPrompt)
            } else {
                if isStoryPrompt {
                    story
                }
                if let hint = presentation.questionHint() {
                    Text(hint)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(presentation.questionHintAccessibilityLabel() ?? hint)
                        .accessibilityIdentifier("liveGame.prompt.selectionHint")
                }
                choices
            }

            if let message = presentation.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("liveGame.prompt.status")
            }

            if let feedback = presentation.serverFeedback {
                Label(feedback, systemImage: "exclamationmark.bubble")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("liveGame.prompt.serverFeedback")
            }

            if presentation.canRetry {
                SemanticActionControl(
                    accessibilityLabel: Text("Retry choice"),
                    semanticFocusID: BoardFocusID.promptRetry,
                    onOutcome: { controller.handle(focusID: $0, $1) },
                    label: { Text("Retry choice") }
                )
                .buttonStyle(.borderedProminent)
                .focused(focusBinding, equals: BoardFocusID.promptRetry)
                .accessibilityHint("Sends the same choice again with version checking.")
                .accessibilityIdentifier("liveGame.prompt.retry")
            }

            if let retry = presentation.catalogRetry {
                SemanticActionControl(
                    accessibilityLabel: Text(retry.title),
                    semanticFocusID: BoardFocusID.promptCatalogRetry,
                    onOutcome: { controller.handle(focusID: $0, $1) },
                    label: { Text(retry.title) }
                )
                .buttonStyle(.borderedProminent)
                .focused(focusBinding, equals: BoardFocusID.promptCatalogRetry)
                .accessibilityHint(retry.accessibilityHint)
                .accessibilityIdentifier("liveGame.prompt.catalogRetry")
            }
        }
        .padding(isCompact ? 14 : 18)
        .frame(maxWidth: isCompact ? .infinity : 360, alignment: .leading)
        .background(background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isStoryPrompt ? "Active story prompt" : "Active choice prompt")
        .accessibilityIdentifier("liveGame.prompt")
    }

    private var standaloneSettingsPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.semanticLocalized(
                "standaloneSettings.message",
                // swiftlint:disable:next line_length
                value: "No scenario setup options are required for this standalone scenario. Continue when ready."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)

            SemanticActionControl(
                accessibilityLabel: Text(presentation.semanticLocalized(
                    "standaloneSettings.submit",
                    value: "Continue"
                )),
                semanticFocusID: BoardFocusID.promptStandaloneSettingsSubmit,
                onOutcome: { controller.handle(focusID: $0, $1) },
                label: {
                    Label(
                        presentation.semanticLocalized(
                            "standaloneSettings.submit",
                            value: "Continue"
                        ),
                        systemImage: "checkmark.circle.fill"
                    )
                }
            )
            .buttonStyle(.borderedProminent)
            .focused(focusBinding, equals: BoardFocusID.promptStandaloneSettingsSubmit)
            .disabled(!presentation.canSubmit)
            .accessibilityHint(presentation.semanticLocalized(
                "standaloneSettings.submit.hint",
                value: "Sends an empty standalone setup answer with version checking."
            ))
            .accessibilityIdentifier("liveGame.prompt.standaloneSettings.submit")
        }
    }

    // swiftlint:disable function_body_length
    private func scenarioSpecificPrompt(
        _ prompt: LaidToRestSpiritDeckPromptPresentation
    ) -> some View {
        let counterText = presentation.semanticLocalized(
            "scenarioSpecific.spiritDeck.counter.format",
            value: "Selected cards: %d of %d",
            arguments: [prompt.selectedCount(controller.spiritDeckSelection), prompt.count]
        )
        return VStack(alignment: .leading, spacing: 10) {
            Text(presentation.semanticLocalized(
                "scenarioSpecific.spiritDeck.message",
                // swiftlint:disable:next line_length
                value: "Choose the cards for the spirit deck. Search is available; class filters from the web view are not shown here."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)

            Text(counterText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    prompt.canConfirm(controller.spiritDeckSelection) ? .green : .secondary
                )
                .accessibilityIdentifier("liveGame.prompt.scenarioSpecific.counter")

            TextField(
                presentation.semanticLocalized(
                    "scenarioSpecific.spiritDeck.search",
                    value: "Search cards"
                ),
                text: Binding(
                    get: { controller.spiritDeckSearchText },
                    set: { controller.setSpiritDeckSearchText($0) }
                )
            )
            .basicChoicePromptSearchTextFieldStyle()
            .focused(focusBinding, equals: BoardFocusID.promptScenarioSpecificSearch)
            .accessibilityLabel(presentation.semanticLocalized(
                "scenarioSpecific.spiritDeck.search",
                value: "Search cards"
            ))
            .accessibilityIdentifier("liveGame.prompt.scenarioSpecific.search")

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.filteredSpiritDeckEntries(for: prompt)) { entry in
                        spiritDeckEntry(entry, prompt: prompt)
                    }
                }
            }
            .frame(maxHeight: 260)

            SemanticActionControl(
                accessibilityLabel: Text(presentation.semanticLocalized(
                    "scenarioSpecific.spiritDeck.submit",
                    value: "Confirm spirit deck"
                )),
                semanticFocusID: BoardFocusID.promptScenarioSpecificSubmit,
                onOutcome: { controller.handle(focusID: $0, $1) },
                label: {
                    Label(
                        presentation.semanticLocalized(
                            "scenarioSpecific.spiritDeck.submit",
                            value: "Confirm spirit deck"
                        ),
                        systemImage: "checkmark.circle.fill"
                    )
                }
            )
            .buttonStyle(.borderedProminent)
            .focused(focusBinding, equals: BoardFocusID.promptScenarioSpecificSubmit)
            .disabled(!presentation.canSubmit || !prompt.canConfirm(controller.spiritDeckSelection))
            .accessibilityHint(presentation.semanticLocalized(
                "scenarioSpecific.spiritDeck.submit.hint",
                value: "Sends your selected spirit deck with version checking."
            ))
            .accessibilityIdentifier("liveGame.prompt.scenarioSpecific.submit")
        }
    }

    // swiftlint:enable function_body_length

    private func spiritDeckEntry(
        _ entry: LaidToRestSpiritDeckPromptPresentation.Entry,
        prompt _: LaidToRestSpiritDeckPromptPresentation
    ) -> some View {
        let selected = entry.code.map { controller.spiritDeckSelection.contains($0) } ?? false
        let title = entry.displayName ?? presentation.semanticLocalized(
            "scenarioSpecific.spiritDeck.unresolvedCard",
            value: "Card unavailable"
        )
        let subtitle = entry.code ?? presentation.semanticLocalized(
            "scenarioSpecific.spiritDeck.malformedCard",
            value: "Malformed card entry"
        )
        return SemanticActionControl(
            accessibilityLabel: Text(spiritDeckAccessibilityLabel(
                title: title, subtitle: subtitle, selected: selected, isFixed: entry.isFixed
            )),
            semanticFocusID: BoardFocusID.promptScenarioSpecificCard(entry.id),
            onOutcome: { controller.handle(focusID: $0, $1) },
            label: {
                HStack(spacing: 8) {
                    Image(systemName: entry.isFixed
                        ? "lock.fill"
                        : selected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected ? .green : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
        .buttonStyle(.bordered)
        .focused(focusBinding, equals: BoardFocusID.promptScenarioSpecificCard(entry.id))
        .disabled(!presentation.canSubmit || !entry.isSelectable)
        .accessibilityHint(spiritDeckAccessibilityHint(entry: entry, selected: selected))
        .accessibilityIdentifier("liveGame.prompt.scenarioSpecific.card.\(entry.id)")
    }

    private func spiritDeckAccessibilityLabel(
        title: String,
        subtitle: String,
        selected: Bool,
        isFixed: Bool
    ) -> String {
        if isFixed {
            return presentation.semanticLocalized(
                "scenarioSpecific.spiritDeck.accessibility.fixed",
                value: "%@, %@, fixed",
                arguments: [title, subtitle]
            )
        }
        let state = selected
            ? presentation.semanticLocalized(
                "scenarioSpecific.spiritDeck.accessibility.selected",
                value: "selected"
            )
            : presentation.semanticLocalized(
                "scenarioSpecific.spiritDeck.accessibility.notSelected",
                value: "not selected"
            )
        return presentation.semanticLocalized(
            "scenarioSpecific.spiritDeck.accessibility.toggle",
            value: "%@, %@, %@",
            arguments: [title, subtitle, state]
        )
    }

    private func spiritDeckAccessibilityHint(
        entry: LaidToRestSpiritDeckPromptPresentation.Entry,
        selected: Bool
    ) -> String {
        if entry.isFixed {
            return presentation.semanticLocalized(
                "scenarioSpecific.spiritDeck.fixed.hint",
                value: "This card is fixed in the spirit deck and cannot be toggled."
            )
        }
        guard entry.isSelectable else {
            return presentation.semanticLocalized(
                "scenarioSpecific.spiritDeck.unselectable.hint",
                // swiftlint:disable:next line_length
                value: "This card cannot be selected because its prompt entry could not be resolved."
            )
        }
        return selected
            ? presentation.semanticLocalized(
                "scenarioSpecific.spiritDeck.selected.hint",
                value: "Removes this card from your spirit deck selection."
            )
            : presentation.semanticLocalized(
                "scenarioSpecific.spiritDeck.unselected.hint",
                value: "Adds this card to your spirit deck selection."
            )
    }

    private func pickDestinyUnavailableAnnouncement(for reason: StoryUnavailableReason) -> String {
        switch reason {
        case .loading:
            pickDestinyLocalized("pickDestiny.names.loading", "Loading tarot names…")
        case .catalog, .imagePipelineUnavailable, .imageSourceLoading, .missingKey,
             .unsupportedEntry, .linkCycle, .missingVariable, .unsupportedVariableValue,
             .tooComplex:
            pickDestinyLocalized(
                "pickDestiny.names.unavailable",
                "The tarot names for this reading are not currently available."
            )
        }
    }

    @ViewBuilder
    private var story: some View {
        if let content = presentation.question.supportedQuestion?.story {
            VStack(alignment: .leading, spacing: 8) {
                if let resolved = presentation.storyResolution?.story {
                    if let title = resolved.title {
                        Text(title)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("liveGame.prompt.story.title")
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(
                                Array(resolved.body.enumerated()), id: \.offset
                            ) { _, entry in
                                ResolvedStoryEntryView(
                                    entry: entry, cardCatalog: presentation.cardCatalog
                                )
                            }
                        }
                    }
                    .frame(maxHeight: isCompact ? 240 : 420)
                    .accessibilityIdentifier("liveGame.prompt.story.body")
                } else {
                    Label(
                        presentation.storyResolution?.unavailableReason?.announcement
                            ?? "This story text is not currently available.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("liveGame.prompt.story.unavailable")
                }
                if let readCards = content.readCards, !readCards.isEmpty {
                    readCardsSummary(readCards)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("liveGame.prompt.story")
        } else if presentation.semanticPresentation?.presentation.flavorText != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let resolved = presentation.storyResolution?.story {
                    if let title = resolved.title {
                        Text(title)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("liveGame.prompt.story.title")
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(resolved.body.enumerated()), id: \.offset) { _, entry in
                                ResolvedStoryEntryView(
                                    entry: entry, cardCatalog: presentation.cardCatalog
                                )
                            }
                        }
                    }
                    .frame(maxHeight: isCompact ? 240 : 420)
                    .accessibilityIdentifier("liveGame.prompt.story.body")
                } else {
                    Label(
                        presentation.storyResolution?.unavailableReason?.announcement
                            ?? "This story text is not currently available.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("liveGame.prompt.story.unavailable")
                }
                if let codes = presentation.semanticPresentation?.presentation.readCards {
                    if !codes.isEmpty {
                        genericReadCardsSummary(codes)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("liveGame.prompt.story")
        }
    }

    private func readCardsSummary(_ codes: [CardCode]) -> some View {
        genericReadCardsSummary(codes.map(\.rawValue))
    }

    private func genericReadCardsSummary(_ codes: [String]) -> some View {
        let joined = codes.joined(separator: ", ")
        return HStack(spacing: 8) {
            Image(systemName: "rectangle.stack.badge.plus")
                .foregroundStyle(.secondary)
            Text(joined)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cards added: \(joined)")
        .accessibilityIdentifier("liveGame.prompt.story.readCards")
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(regularChoices) { choice in
                choiceButton(for: choice, isFinishingAction: false)
            }
            if !finishingChoices.isEmpty {
                Divider()
                ForEach(finishingChoices) { choice in
                    choiceButton(for: choice, isFinishingAction: true)
                }
            }
        }
    }

    private var regularChoices: [BasicChoice] {
        presentation.displayOrderedChoices().filter {
            !presentation.isCompletingSelection($0)
        }
    }

    private var finishingChoices: [BasicChoice] {
        presentation.displayOrderedChoices().filter {
            presentation.isCompletingSelection($0)
        }
    }

    @ViewBuilder
    private func choiceButton(
        for choice: BasicChoice,
        isFinishingAction: Bool
    ) -> some View {
        if isFinishingAction {
            choiceControl(for: choice)
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
        } else {
            choiceControl(for: choice)
                .buttonStyle(.bordered)
                .tint(choiceTint(for: choice))
        }
    }

    private func choiceControl(for choice: BasicChoice) -> some View {
        let focusID = BoardFocusID.promptChoice(choice.index)
        let resolved = presentation.resolvedChoiceLabel(
            for: choice,
            in: controller.projection,
            revealsHandCardFaces: revealsPromptOwnerHandCardFaces
        )
        let title = resolved.title
        let isActionable = presentation.isChoiceActionable(
            choice, in: controller.projection
        )
        return SemanticActionControl(
            accessibilityLabel: Text(resolved.accessibilityLabel),
            semanticFocusID: focusID,
            onOutcome: { controller.handle(focusID: $0, $1) },
            label: {
                HStack(spacing: 10) {
                    Image(systemName: resolved.systemImage)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        if let subtitle = resolved.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    let isSendingChoice = presentation.actionChoiceIndex == choice.index
                        && presentation.actionPhase == .sending
                    if isSendingChoice {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
            }
        )
        .focused(focusBinding, equals: focusID)
        .disabled(!isActionable || !presentation.canSubmit)
        // `SemanticActionControl` already applies `accessibilityLabel: Text(title)`
        // internally; an outer override here would risk silently diverging from it.
        .accessibilityHint(accessibilityHint(for: choice))
        .accessibilityIdentifier("liveGame.prompt.choice.\(choice.index)")
    }

    @ViewBuilder
    private var background: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.platformPromptBackground)
        } else {
            RoundedRectangle(cornerRadius: 18)
                .fill(.regularMaterial)
        }
    }

    /// A choice's semantic title, or its legacy raw fallback title when the semantic
    /// envelope is absent, resolved against the current authoritative board projection.
    private func displayTitle(for choice: BasicChoice) -> String {
        presentation.displayTitle(
            for: choice,
            in: controller.projection,
            revealsHandCardFaces: revealsPromptOwnerHandCardFaces
        )
    }

    private func accessibilityHint(for choice: BasicChoice) -> String {
        presentation.accessibilityHint(for: choice, in: controller.projection)
    }

    private func choiceTint(for choice: BasicChoice) -> Color? {
        guard let descriptor = presentation.semanticPresentation?.descriptor(
            forSourceIndex: choice.index
        ) else { return nil }
        switch descriptor.kind {
        case .info:
            return .blue
        case .invalidLabel:
            return .secondary
        default:
            return nil
        }
    }
}

private extension View {
    @ViewBuilder
    func basicChoicePromptSearchTextFieldStyle() -> some View {
        #if os(tvOS)
            self
        #else
            textFieldStyle(.roundedBorder)
        #endif
    }
}

private extension Color {
    static var platformPromptBackground: Color {
        #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #elseif os(tvOS)
            Color.black.opacity(0.85)
        #else
            Color(uiColor: .systemBackground)
        #endif
    }
}
