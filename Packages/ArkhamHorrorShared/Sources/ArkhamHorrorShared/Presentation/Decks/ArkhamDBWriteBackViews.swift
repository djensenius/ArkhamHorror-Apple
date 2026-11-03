import SwiftUI

/// Per-deck write-back toggle, push status and actions shown inside a saved-deck row.
struct ArkhamDBWriteBackRowSection: View {
    @Bindable var model: ArkhamDBViewModel
    let deck: Deck
    let status: ArkhamDBWriteBackStatus

    private var id: String {
        deck.id.rawValue.uuidString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { status.enabled },
                set: { enabled in Task { await model.setWriteBack(deck.id, enabled: enabled) } }
            )) {
                Text(arkhamDBLocalized("writeBack.toggle")).font(.caption)
            }
            .disabled(model.isBusy)
            .accessibilityLabel(String(
                format: arkhamDBLocalized("writeBack.toggleAccessibility"), deck.name
            ))
            .accessibilityIdentifier("arkhamdb.writeBack.toggle.\(id)")
            if status.enabled || status.state != .idle {
                Text(status.statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("arkhamdb.writeBack.status.\(id)")
            }
            if status.showsSpentXpNote {
                Text(arkhamDBLocalized("writeBack.spentXp"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("arkhamdb.writeBack.spentXp.\(id)")
            }
            actions
        }
    }

    private var statusColor: Color {
        switch status.state {
        case .failed, .conflict: .red
        case .succeeded: .green
        default: .secondary
        }
    }

    @ViewBuilder
    private var actions: some View {
        if status.canRetry {
            Button(arkhamDBLocalized("writeBack.retry")) {
                Task { await model.retryWriteBack(deck.id) }
            }
            .buttonStyle(.borderless)
            .disabled(model.isBusy)
            .accessibilityLabel(String(
                format: arkhamDBLocalized("writeBack.retryAccessibility"), deck.name
            ))
            .accessibilityIdentifier("arkhamdb.writeBack.retry.\(id)")
        }
        if status.opensResolution {
            Button(arkhamDBLocalized(
                status.allowedResolutions.isEmpty ? "writeBack.details" : "writeBack.resolve"
            )) {
                model.openResolution(deck.id)
            }
            .buttonStyle(.borderless)
            .disabled(model.isBusy)
            .accessibilityLabel(String(
                format: arkhamDBLocalized("writeBack.resolveAccessibility"), deck.name
            ))
            .accessibilityIdentifier("arkhamdb.writeBack.resolve.\(id)")
        }
    }
}

/// The resolution sheet offers only the server-accepted resolutions for the row.
struct ArkhamDBWriteBackConflictSheet: View {
    @Bindable var model: ArkhamDBViewModel
    let deckName: String
    let status: ArkhamDBWriteBackStatus

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(status.statusText)
                        .accessibilityIdentifier("arkhamdb.writeBack.conflict.reason")
                    if status.blockedReason != nil {
                        Text(arkhamDBLocalized("writeBack.blocked"))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("arkhamdb.writeBack.conflict.blocked")
                    }
                    if status.showsSpentXpNote {
                        Text(arkhamDBLocalized("writeBack.spentXp"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let message = model.message {
                        ArkhamFailureText(message: message)
                    }
                }
                ForEach(status.allowedResolutions, id: \.self) { resolution in
                    Section {
                        Button(
                            arkhamDBLocalized(resolution.titleKey),
                            role: resolution == .overwrite ? .destructive : nil
                        ) {
                            let deckID = status.localDeckId
                            Task { await model.chooseResolution(resolution, for: deckID) }
                        }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("arkhamdb.writeBack.\(resolution.rawValue)")
                    } footer: {
                        Text(arkhamDBLocalized(resolution.explanationKey))
                    }
                }
            }
            .navigationTitle(deckName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(arkhamDBLocalized("cancel")) { model.closeResolution() }
                        .accessibilityIdentifier("arkhamdb.writeBack.conflict.close")
                }
            }
            .confirmationDialog(
                model.pendingConfirmation.map {
                    String(format: arkhamDBLocalized($0.resolution.confirmationTitleKey), deckName)
                } ?? "",
                isPresented: Binding(
                    get: { model.pendingConfirmation != nil },
                    set: {
                        if !$0 {
                            model.cancelPendingResolution()
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: model.pendingConfirmation
            ) { pending in
                Button(arkhamDBLocalized(pending.resolution.titleKey), role: .destructive) {
                    Task { await model.confirmPendingResolution() }
                }
                .accessibilityIdentifier("arkhamdb.writeBack.confirm")
                Button(arkhamDBLocalized("cancel"), role: .cancel) {
                    model.cancelPendingResolution()
                }
            } message: { pending in
                Text(arkhamDBLocalized(pending.resolution.explanationKey))
            }
        }
    }
}

extension View {
    /// Presents the conflict sheet for the deck the model is resolving, if any.
    func arkhamDBWriteBackConflictSheet(model: ArkhamDBViewModel?, decks: [Deck]) -> some View {
        sheet(isPresented: Binding(
            get: { model?.resolvingStatus != nil },
            set: {
                if !$0 {
                    model?.closeResolution()
                }
            }
        )) {
            if let model, let status = model.resolvingStatus {
                ArkhamDBWriteBackConflictSheet(
                    model: model,
                    deckName: decks.first { $0.id == status.localDeckId }?.name
                        ?? arkhamDBLocalized("writeBack.conflictTitle"),
                    status: status
                )
            }
        }
    }
}
