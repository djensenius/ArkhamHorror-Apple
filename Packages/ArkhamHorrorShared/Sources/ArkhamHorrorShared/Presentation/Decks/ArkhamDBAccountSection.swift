import SwiftUI

struct ArkhamDBAccountSection: View {
    @Bindable var model: ArkhamDBViewModel
    let onImported: (Deck) -> Void

    private var linkLabel: String {
        arkhamDBLocalized(model.status?.linked == true ? "relink" : "link")
    }

    var body: some View {
        Section(arkhamDBLocalized("account")) {
            Text(model.statusText)
                .accessibilityIdentifier("arkhamdb.status")
                .task { await model.refreshStatus() }
            if model.isBusy {
                ProgressView().accessibilityLabel(arkhamDBLocalized("loading"))
            }
            if let message = model.message {
                ArkhamFailureText(message: message)
                    .accessibilityIdentifier("arkhamdb.message")
            }
            #if os(tvOS)
                if model.status?.linked != true {
                    Text(arkhamDBLocalized("anotherDevice"))
                }
            #else
                Button(linkLabel) {
                    Task { await model.link() }
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("arkhamdb.link")
            #endif
            if model.status?.linked == true {
                NavigationLink(arkhamDBLocalized("decks")) {
                    ArkhamDBDeckBrowser(model: model, onImported: onImported)
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("arkhamdb.decks")
                Button(arkhamDBLocalized("unlink"), role: .destructive) {
                    model.confirmsUnlink = true
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("arkhamdb.unlink")
                .confirmationDialog(
                    arkhamDBLocalized("unlinkConfirmation"), isPresented: $model.confirmsUnlink,
                    titleVisibility: .visible
                ) {
                    Button(arkhamDBLocalized("unlink"), role: .destructive) {
                        Task { await model.unlink() }
                    }
                    Button(arkhamDBLocalized("cancel"), role: .cancel) {}
                } message: {
                    Text(arkhamDBLocalized("unlinkExplanation"))
                }
            }
            Button(arkhamDBLocalized("refresh")) {
                Task { await model.refreshStatus() }
            }
            .disabled(model.isBusy)
        }
    }
}

private struct ArkhamDBDeckBrowser: View {
    @Bindable var model: ArkhamDBViewModel
    let onImported: (Deck) -> Void

    var body: some View {
        List {
            if let message = model.message {
                ArkhamFailureText(message: message)
            }
            if model.needsRelinking {
                #if os(tvOS)
                    Text(arkhamDBLocalized("anotherDevice"))
                #else
                    Button(arkhamDBLocalized("relink")) { Task { await model.link() } }
                        .disabled(model.isBusy)
                #endif
            }
            if model.skippedCount > 0 {
                Text(arkhamDBSkippedText(model.skippedCount))
                    .accessibilityIdentifier("arkhamdb.skipped")
            }
            if model.isBusy {
                ProgressView().accessibilityLabel(arkhamDBLocalized("loading"))
            } else if model.showsEmptyDecks {
                Text(arkhamDBLocalized("empty"))
            }
            ForEach(Array(model.decks.enumerated()), id: \.offset) { _, deck in
                VStack(alignment: .leading, spacing: 4) {
                    Text(deck.name).font(.headline)
                    if let investigator = deck.investigatorName {
                        Text(investigator).font(.subheadline)
                    }
                    if let updated = arkhamDBUpdatedText(deck.lastUpdatedAt) {
                        Text(updated)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if deck.linkedLocalDeckId != nil {
                        Label(arkhamDBLocalized("imported"), systemImage: "checkmark.circle")
                    } else {
                        Button(arkhamDBLocalized("import")) {
                            Task { await model.importDeck(deck, onImported: onImported) }
                        }
                        .disabled(model.isBusy)
                        .accessibilityLabel(String(
                            format: arkhamDBLocalized("importAccessibility"),
                            deck.name
                        ))
                        .accessibilityIdentifier("arkhamdb.import.\(deck.id)")
                    }
                }
            }
        }
        .navigationTitle(arkhamDBLocalized("decks"))
        .toolbar {
            Button(arkhamDBLocalized("refresh")) { Task { await model.loadDecks() } }
                .disabled(model.isBusy)
        }
        .onAppear { model.isDeckBrowserOpen = true }
        .onDisappear { model.isDeckBrowserOpen = false }
        .task { await model.loadDecks() }
        .refreshable { await model.loadDecks() }
    }
}
