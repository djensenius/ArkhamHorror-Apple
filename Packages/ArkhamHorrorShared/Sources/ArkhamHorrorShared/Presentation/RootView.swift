import SwiftUI

/// The shared root view for every platform target.
///
/// Switches on a typed ``AccountRoute`` derived from ``AppModel/sessionState`` (and the
/// full saved profile list) so every coordinator state from launch through storage
/// corruption has an explicit, native presentation with no stale-content flash: the
/// route (and the view it selects) changes atomically with the observed state, never
/// leaving a prior screen's content visible while a new one loads.
///
/// The public, parameterless initializer constructs a production ``AppModel`` (real
/// ``UserDefaultsServerProfileStore``, ``KeychainTokenStore``, ``CapabilityProbe``, and
/// ``AuthenticationSession``); an internal initializer exists solely so previews and
/// `@testable` tests within this module can inject a fully fake ``AppModel`` without
/// exposing that internal type as public API or touching the network or Keychain.
public struct RootView: View {
    @State private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {
        self.init(model: AppModel())
    }

    /// Not `public`: `AppModel` is an internal implementation type. Previews and
    /// `@testable` tests within this module use this to inject fakes.
    init(model: AppModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        let route = AccountRoute(sessionState: model.sessionState, profiles: model.profiles)
        ZStack {
            ArkhamTheme.backgroundGradient.ignoresSafeArea()
            NavigationStack {
                content(for: route)
                    .navigationTitle("Arkham Horror")
                #if os(iOS) || os(visionOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
            }
        }
        .foregroundStyle(ArkhamTheme.bone)
        .animation(reduceMotion ? nil : .default, value: route)
    }

    @ViewBuilder
    private func content(for route: AccountRoute) -> some View {
        switch route {
        case let .launch(profileName):
            LaunchProgressView(profileName: profileName)
        case let .serverSelection(profiles, selected, compatibility):
            ServerSelectionView(
                model: model, profiles: profiles, selected: selected, compatibility: compatibility
            )
        case let .incompatible(profile, reason):
            ServerIssueView(model: model, kind: .incompatible(profile: profile, reason: reason))
        case let .unavailable(profile, reason):
            ServerIssueView(model: model, kind: .unavailable(profile: profile, reason: reason))
        case let .storageCorrupted(failure):
            ServerIssueView(model: model, kind: .storageCorrupted(failure))
        case let .account(profile, compatibility, user):
            AccountShellView(
                model: model, profile: profile, compatibility: compatibility, user: user
            )
        }
    }
}

#Preview("Root – launching") {
    RootView(model: previewAppModel())
}
