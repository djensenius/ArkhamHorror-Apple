@testable import ArkhamHorrorShared
import Testing

/// Architecture coverage for the per-window coordinator fix: stores and the Keychain
/// are process-global, so every window a platform's `WindowGroup` presents (multiple
/// simultaneous windows on macOS/visionOS/iPad) must share exactly one process-level
/// `AppModel` rather than each constructing its own independent, side-effectful
/// coordinator that would race the same underlying storage.
///
/// This suite deliberately never calls `RootView`'s public, parameterless initializer:
/// that initializer wires the real, production `AppModel()` (live `UserDefaults`,
/// Keychain, and a hosted-server network probe), which must never run inside a test
/// process. The "every window shares one instance" guarantee itself is Swift's
/// language-level `static let` semantics on `RootView.productionModel` (evaluated
/// exactly once, thread-safely, on first access) — verifiable by inspection: exactly
/// one `AppModel()` construction site exists in `RootView.swift`, reached only through
/// that shared static. What *is* safely testable here, without touching any
/// production dependency, is that the internal injection seam (`init(model:)`) that
/// both `productionModel`'s wiring and every test/preview use is itself
/// identity-correct: it stores exactly the instance it is given, and distinct
/// instances remain distinguishable.
@MainActor
@Suite("RootView — coordinator injection seam")
struct RootViewSharedModelTests {
    private func fakeModel() -> AppModel {
        AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
    }

    @Test("The internal init(model:) seam stores exactly the instance it is given")
    func injectionSeamPreservesIdentity() {
        let model = fakeModel()
        let view = RootView(model: model)

        #expect(view.modelIdentityForArchitectureTest == ObjectIdentifier(model))
    }

    @Test("Two RootViews injected with distinct AppModel instances remain distinguishable")
    func distinctInjectedModelsRemainDistinguishable() {
        let first = RootView(model: fakeModel())
        let second = RootView(model: fakeModel())

        #expect(first.modelIdentityForArchitectureTest != second.modelIdentityForArchitectureTest)
    }

    @Test("Two RootViews injected with the very same AppModel instance share identity")
    func sameInjectedModelSharesIdentity() {
        // Mirrors how every production window is wired to the one shared
        // `productionModel`: two views constructed from the identical underlying
        // instance must report the identical identity.
        let shared = fakeModel()
        let first = RootView(model: shared)
        let second = RootView(model: shared)

        #expect(first.modelIdentityForArchitectureTest == second.modelIdentityForArchitectureTest)
    }
}
