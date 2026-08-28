import SwiftUI

/// The signed-out landing screen: lets the user pick among saved servers (hosted or
/// custom) and enter sign-in or registration, or manage custom servers.
///
/// Presented for ``AccountRoute/serverSelection(profiles:selected:compatibility:)``.
struct ServerSelectionView: View {
    let model: AppModel
    let profiles: [ServerProfile]
    let selected: ServerProfile
    let compatibility: ServerCompatibility

    private enum PresentedSheet: Identifiable {
        case signIn
        case register
        case manageServers

        var id: Self {
            self
        }
    }

    @State private var presentedSheet: PresentedSheet?
    @AccessibilityFocusState private var isHeaderFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ArkhamHeader("Arkham Horror", subtitle: "Choose your server to continue")
                    .accessibilityFocused($isHeaderFocused)

                serverList

                ArkhamCard {
                    Text("Sign in or create an account on \(selected.displayName).")
                        .font(.subheadline)
                        .foregroundStyle(ArkhamTheme.bone.opacity(0.8))

                    ArkhamPrimaryButton("Sign In", systemImage: "arrow.right.circle.fill") {
                        presentedSheet = .signIn
                    }
                    .accessibilityIdentifier(AccountAccessibilityID.signInEntryButton)

                    Button("Create Account") {
                        presentedSheet = .register
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(AccountAccessibilityID.registerEntryButton)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear { isHeaderFocused = true }
        .sheet(item: $presentedSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .signIn:
                    SignInView(model: model)
                case .register:
                    RegisterView(model: model)
                case .manageServers:
                    ServerManagementView(model: model)
                }
            }
        }
    }

    private var serverList: some View {
        ArkhamCard {
            HStack {
                Text("Server")
                    .font(.headline)
                    .foregroundStyle(ArkhamTheme.bone)
                Spacer()
                if compatibility == .legacy {
                    Text("Legacy")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.25), in: Capsule())
                        .accessibilityLabel("Legacy compatibility mode")
                }
            }

            ForEach(profiles) { profile in
                Button {
                    guard profile.id != selected.id else { return }
                    model.selectProfile(profile)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                                .font(.body)
                                .foregroundStyle(ArkhamTheme.bone)
                            Text(profile.endpointSummary)
                                .font(.caption)
                                .foregroundStyle(ArkhamTheme.bone.opacity(0.6))
                        }
                        Spacer()
                        if profile.id == selected.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(ArkhamTheme.accent)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(profile.id == selected.id ? [.isSelected] : [])
            }

            Button {
                presentedSheet = .manageServers
            } label: {
                Label("Manage Servers", systemImage: "server.rack")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ArkhamTheme.accent)
            .accessibilityIdentifier(AccountAccessibilityID.manageServersButton)
        }
    }
}

#Preview("Server selection – modern hosted") {
    ServerSelectionView(
        model: previewAppModel(outcome: .compatible(capabilities: [])),
        profiles: [.hosted],
        selected: .hosted,
        compatibility: .modern(capabilities: [])
    )
    .background(ArkhamTheme.backgroundGradient)
}
