import SwiftUI

/// Custom server management: lists every saved profile, and lets the user add, edit, or
/// remove a custom one. The canonical hosted profile is shown but is immutable and
/// cannot be removed.
struct ServerManagementView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum PresentedSheet: Identifiable {
        case add
        case edit(ServerProfile)

        var id: String {
            switch self {
            case .add: "add"
            case let .edit(profile): "edit-\(profile.id)"
            }
        }
    }

    @State private var presentedSheet: PresentedSheet?
    @State private var pendingRemoval: ServerProfile?

    var body: some View {
        List {
            Section {
                ForEach(model.profiles) { profile in
                    row(for: profile)
                }
            } footer: {
                if let failure = model.profileManagementFailure {
                    ArkhamFailureText(message: failure.message)
                }
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentedSheet = .add
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .accessibilityIdentifier(AccountAccessibilityID.addServerButton)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .add:
                    ServerProfileEditorView(model: model, mode: .add)
                case let .edit(profile):
                    ServerProfileEditorView(model: model, mode: .edit(profile))
                }
            }
        }
        .confirmationDialog(
            "Remove this server?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: {
                    if !$0 {
                        pendingRemoval = nil
                    }
                }
            ),
            presenting: pendingRemoval
        ) { profile in
            Button("Remove \(profile.displayName)", role: .destructive) {
                model.removeCustomProfile(profile)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { profile in
            Text("This removes \"\(profile.displayName)\" and its saved sign-in.")
        }
    }

    private func row(for profile: ServerProfile) -> some View {
        Button {
            guard profile.id != model.selectedProfile.id else { return }
            model.selectProfile(profile)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.body)
                    Text(profile.baseURL.host ?? profile.baseURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if profile.id == model.selectedProfile.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ArkhamTheme.accent)
                        .accessibilityLabel("Currently selected")
                }
                if profile.kind == .hosted {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Built-in server; can't be edited or removed")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(profile.id == model.selectedProfile.id ? [.isSelected] : [])
        .modifier(CustomProfileSwipeActions(
            profile: profile, onEdit: { presentedSheet = .edit(profile) },
            onRemove: { pendingRemoval = profile }
        ))
        .contextMenu {
            if profile.kind == .custom {
                Button {
                    presentedSheet = .edit(profile)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingRemoval = profile
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }
}

/// Applies swipe-to-edit/remove actions on platforms that support list swipe gestures
/// (iOS, iPadOS, macOS, visionOS); a no-op on tvOS, where the equivalent context menu
/// (already attached alongside this modifier) is the native, focus-driven path instead.
private struct CustomProfileSwipeActions: ViewModifier {
    let profile: ServerProfile
    let onEdit: () -> Void
    let onRemove: () -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
            content
        #else
            content.swipeActions(edge: .trailing) {
                if profile.kind == .custom {
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove", systemImage: "trash")
                    }
                    .accessibilityIdentifier(AccountAccessibilityID.serverRemoveButton)

                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(ArkhamTheme.accent)
                }
            }
        #endif
    }
}

/// The add/edit form for a custom server profile: display name and address, with
/// inline, non-secret validation reusing ``ServerProfile`` validation rather than
/// duplicating any URL parsing.
struct ServerProfileEditorView: View {
    enum Mode {
        case add
        case edit(ServerProfile)
    }

    let model: AppModel
    let mode: Mode
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String
    @State private var rawURL: String
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case displayName
        case url
    }

    init(model: AppModel, mode: Mode) {
        self.model = model
        self.mode = mode
        switch mode {
        case .add:
            _displayName = State(initialValue: "")
            _rawURL = State(initialValue: "")
        case let .edit(profile):
            _displayName = State(initialValue: profile.displayName)
            _rawURL = State(initialValue: profile.baseURL.absoluteString)
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $displayName)
                    .focused($focusedField, equals: .displayName)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .url }
                    .accessibilityIdentifier(AccountAccessibilityID.serverDisplayNameField)

                TextField("https://example.com", text: $rawURL)
                    .urlFieldStyle()
                    .focused($focusedField, equals: .url)
                    .submitLabel(.done)
                    .onSubmit(submit)
                    .accessibilityIdentifier(AccountAccessibilityID.serverURLField)
            } footer: {
                if let failure = model.profileManagementFailure {
                    ArkhamFailureText(message: failure.message)
                } else {
                    Text(
                        "Enter the server's address without the API path; it's added automatically."
                    )
                }
            }

            Section {
                ArkhamPrimaryButton(
                    "Save",
                    isLoading: isSaving,
                    action: submit
                )
                .disabled(!isValid || isSaving)
                .accessibilityIdentifier(AccountAccessibilityID.serverEditorSaveButton)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle(navigationTitle)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onAppear { focusedField = .displayName }
        .onChange(of: model.profileManagementOperation) { _, newValue in
            guard newValue == .idle, model.profileManagementFailure == nil else { return }
            dismiss()
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .add: "Add Server"
        case .edit: "Edit Server"
        }
    }

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSaving: Bool {
        switch (mode, model.profileManagementOperation) {
        case (.add, .saving), (.edit, .saving):
            true
        default:
            false
        }
    }

    private func submit() {
        guard isValid else { return }
        switch mode {
        case .add:
            model.addCustomProfile(displayName: displayName, rawURL: rawURL)
            if model.profileManagementFailure == nil {
                dismiss()
            }
        case let .edit(profile):
            model.updateCustomProfile(profile, displayName: displayName, rawURL: rawURL)
        }
    }
}

#Preview("Manage Servers") {
    NavigationStack {
        ServerManagementView(model: previewAppModel(profiles: [.hosted]))
    }
}

#Preview("Add Server") {
    NavigationStack {
        ServerProfileEditorView(model: previewAppModel(), mode: .add)
    }
}
