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
    /// The single process-level coordinator shared by every window this app presents.
    ///
    /// Stores and the Keychain are process-global, so if each `RootView` constructed
    /// its own `AppModel`, independent windows (as macOS, visionOS, and iPad
    /// multiwindow all allow) would race independent in-memory session/profile state
    /// against the very same underlying storage. A `static let` is evaluated exactly
    /// once — by whichever window's initializer runs first — and every subsequent
    /// window (and every call to the public, parameterless initializer) observes and
    /// reuses that same instance, making shared-model launch idempotent even if
    /// multiple windows appear at once. No production `RootView` may construct an
    /// independent coordinator; the internal ``init(model:)`` below exists solely so
    /// previews and tests can inject a fake one instead of touching this shared,
    /// side-effectful instance.
    @MainActor
    private static let productionModel = AppModel()

    @State private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {
        self.init(model: RootView.productionModel)
    }

    /// Not `public`: `AppModel` is an internal implementation type. Previews and
    /// `@testable` tests within this module use this to inject fakes.
    init(model: AppModel) {
        _model = State(initialValue: model)
    }

    /// The underlying coordinator's identity, exposed solely so an `@testable` test
    /// can verify that multiple production ``RootView()`` windows share one
    /// process-level ``AppModel`` instance rather than each racing an independent
    /// one against the same process-global stores.
    var modelIdentityForArchitectureTest: ObjectIdentifier {
        ObjectIdentifier(model)
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
        case let .credentialCleanupRegistryCorrupted(failure):
            ServerIssueView(model: model, kind: .credentialCleanupRegistryCorrupted(failure))
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
