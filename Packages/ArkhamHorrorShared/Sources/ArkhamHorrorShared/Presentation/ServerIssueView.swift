import SwiftUI

/// The recoverable-problem presentation for an incompatible, unavailable, or
/// storage-corrupted session, each with an accurate, non-secret reason category and an
/// actionable path forward (retry, choose a different server, or an explicit,
/// user-confirmed storage reset). Never surfaces a raw transport, decoder, or Keychain
/// diagnostic string.
struct ServerIssueView: View {
    enum Kind {
        case incompatible(profile: ServerProfile, reason: CompatibilityRejection)
        case unavailable(profile: ServerProfile, reason: SessionUnavailableReason)
        case storageCorrupted(SessionStorageFailure)
    }

    let model: AppModel
    let kind: Kind

    @State private var isPresentingResetConfirmation = false
    @State private var isPresentingServerManagement = false
    @AccessibilityFocusState private var isHeaderFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ArkhamHeader(title, subtitle: profileName)
                    .accessibilityFocused($isHeaderFocused)

                ArkhamCard {
                    Label {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(ArkhamTheme.bone.opacity(0.85))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }

                    actions
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear { isHeaderFocused = true }
        .confirmationDialog(
            "Reset saved server data?",
            isPresented: $isPresentingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset and Continue", role: .destructive) {
                model.confirmStorageReset()
            }
            .accessibilityIdentifier(AccountAccessibilityID.storageResetConfirmButton)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This restores only the default hosted server and removes saved sign-in "
                    + "tokens. Custom servers you saved will be removed."
            )
        }
        .sheet(isPresented: $isPresentingServerManagement) {
            NavigationStack {
                ServerManagementView(model: model)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch kind {
        case let .incompatible(profile, _):
            Button {
                isPresentingServerManagement = true
            } label: {
                Label("Choose a Different Server", systemImage: "server.rack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccountAccessibilityID.chooseServerButton)

            PendingCleanupRetryBanner(model: model, profileID: profile.id)
        case let .unavailable(profile, _):
            ArkhamPrimaryButton("Retry", systemImage: "arrow.clockwise") {
                model.retry()
            }
            .accessibilityIdentifier(AccountAccessibilityID.retryButton)

            Button {
                isPresentingServerManagement = true
            } label: {
                Label("Choose a Different Server", systemImage: "server.rack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccountAccessibilityID.chooseServerButton)

            PendingCleanupRetryBanner(model: model, profileID: profile.id)
        case .storageCorrupted:
            if model.profileManagementOperation == .resettingStorage {
                ProgressView("Resetting…")
                    .frame(maxWidth: .infinity)
            } else {
                Button(role: .destructive) {
                    isPresentingResetConfirmation = true
                } label: {
                    Label("Reset Saved Servers…", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.profileManagementOperation != .idle)
                .accessibilityIdentifier(AccountAccessibilityID.storageResetEntryButton)
            }
            if let failure = model.profileManagementFailure {
                Text(failure.message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(AccountAccessibilityID.profileManagementFailureText)
            }
        }
    }

    private var title: String {
        switch kind {
        case .incompatible: "Server Incompatible"
        case .unavailable: "Server Unavailable"
        case .storageCorrupted: "Storage Problem"
        }
    }

    private var profileName: String? {
        switch kind {
        case let .incompatible(profile, _): profile.displayName
        case let .unavailable(profile, _): profile.displayName
        case .storageCorrupted: nil
        }
    }

    private var message: String {
        switch kind {
        case let .incompatible(_, reason): reason.message
        case let .unavailable(_, reason): reason.message
        case let .storageCorrupted(failure): failure.message
        }
    }
}

#Preview("Incompatible") {
    ServerIssueView(
        model: previewAppModel(),
        kind: .incompatible(
            profile: .hosted,
            reason: .serverTooOld(
                serverRevision: .literal(major: 0, minor: 9, patch: 0),
                clientRequires: .literal(major: 1, minor: 0, patch: 0)
            )
        )
    )
    .background(ArkhamTheme.backgroundGradient)
}

#Preview("Unavailable") {
    ServerIssueView(
        model: previewAppModel(),
        kind: .unavailable(profile: .hosted, reason: .probeFailed(.nonHTTPResponse))
    )
    .background(ArkhamTheme.backgroundGradient)
}

#Preview("Storage Corrupted") {
    ServerIssueView(
        model: previewAppModel(),
        kind: .storageCorrupted(.profileStore(.corruptData(key: "ArkhamHorror.serverProfiles")))
    )
    .background(ArkhamTheme.backgroundGradient)
}
