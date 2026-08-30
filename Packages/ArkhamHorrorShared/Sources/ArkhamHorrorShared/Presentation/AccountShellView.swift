import SwiftUI

/// The signed-in landing shell: an adaptive native games/lobby list, with account
/// details (typed current user, connected server, switch-server, and sign-out)
/// reachable from the toolbar rather than displacing the primary games surface.
///
/// Presented for ``AccountRoute/account(profile:compatibility:user:)``.
struct AccountShellView: View {
    let model: AppModel
    let profile: ServerProfile
    let compatibility: ServerCompatibility
    let user: CurrentUser

    @State private var isPresentingAccountDetail = false

    var body: some View {
        GamesListView(model: model)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        isPresentingAccountDetail = true
                    } label: {
                        Label(user.username, systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier(AccountAccessibilityID.accountDetailButton)
                }
            }
            .sheet(isPresented: $isPresentingAccountDetail) {
                NavigationStack {
                    AccountDetailView(
                        model: model, profile: profile, compatibility: compatibility, user: user
                    )
                }
            }
    }
}

/// The account details sheet: typed current user, connected server, switch-server,
/// and sign-out actions. Presented from ``AccountShellView``'s toolbar.
struct AccountDetailView: View {
    let model: AppModel
    let profile: ServerProfile
    let compatibility: ServerCompatibility
    let user: CurrentUser

    @Environment(\.dismiss) private var dismiss
    @State private var isPresentingServerSwitch = false
    @AccessibilityFocusState private var isHeaderFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ArkhamHeader("Welcome, \(user.username)", subtitle: user.email)
                    .accessibilityFocused($isHeaderFocused)

                ArkhamCard {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(ArkhamTheme.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                                .font(.headline)
                                .foregroundStyle(ArkhamTheme.bone)
                            Text(
                                compatibility == .legacy ? "Legacy compatibility mode" : "Connected"
                            )
                            .font(.caption)
                            .foregroundStyle(ArkhamTheme.bone.opacity(0.6))
                        }
                        Spacer()
                    }

                    if user.beta {
                        Label("Beta features enabled", systemImage: "flask")
                            .font(.caption)
                            .foregroundStyle(ArkhamTheme.bone.opacity(0.7))
                    }

                    Divider()

                    Button {
                        isPresentingServerSwitch = true
                    } label: {
                        Label("Switch Server", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(AccountAccessibilityID.switchServerButton)

                    Button(role: .destructive) {
                        model.signOut()
                    } label: {
                        HStack {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                            if model.operation == .signingOut {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.operation == .signingOut)
                    .accessibilityIdentifier(AccountAccessibilityID.signOutButton)

                    if let failure = model.operationFailure {
                        ArkhamFailureText(message: failure.message)
                            .accessibilityIdentifier(AccountAccessibilityID.operationFailureText)
                    }

                    PendingCleanupRetryBanner(model: model, profileID: profile.id)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear { isHeaderFocused = true }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $isPresentingServerSwitch) {
            NavigationStack {
                ServerManagementView(model: model)
            }
        }
    }
}

#Preview("Account – modern") {
    AccountShellView(
        model: previewAppModel(outcome: .compatible(capabilities: [])),
        profile: .hosted,
        compatibility: .modern(capabilities: []),
        user: .previewSample
    )
    .background(ArkhamTheme.backgroundGradient)
    .foregroundStyle(ArkhamTheme.bone)
}

#Preview("Account – legacy") {
    AccountShellView(
        model: previewAppModel(),
        profile: .hosted,
        compatibility: .legacy,
        user: .previewSample
    )
    .background(ArkhamTheme.backgroundGradient)
    .foregroundStyle(ArkhamTheme.bone)
}
