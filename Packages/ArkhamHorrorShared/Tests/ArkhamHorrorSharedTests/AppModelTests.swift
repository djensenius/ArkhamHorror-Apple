@testable import ArkhamHorrorShared
import Testing

/// Deterministic coverage for ``AppModel``'s startup, compatibility, token restoration,
/// authentication, sign-out, and profile-switching behaviors (issue #14). Test
/// functions are grouped by concern across the `AppModel*Tests.swift` files in this
/// directory; shared fakes/fixtures live in `AppModelTestSupport.swift`.
@MainActor
@Suite("AppModel")
struct AppModelTests {}
