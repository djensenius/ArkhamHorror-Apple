import CoreGraphics

/// The deterministic state a presentation-layer asset loader can be in.
///
/// Every case (other than ``idle``) carries the caller-supplied accessible
/// description, so a view can always provide an accessibility label
/// regardless of whether the underlying image has loaded yet or failed.
enum AssetLoadState: Equatable {
    case idle
    case loading(accessibleDescription: String)
    case success(CGImage, accessibleDescription: String)
    case failure(AssetError, accessibleDescription: String)

    var accessibleDescription: String? {
        switch self {
        case .idle:
            nil
        case let .loading(description), let .success(_, description), let .failure(_, description):
            description
        }
    }

    static func == (lhs: AssetLoadState, rhs: AssetLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            true
        case let (.loading(lhsDescription), .loading(rhsDescription)):
            lhsDescription == rhsDescription
        case let (.success(lImage, lDescription), .success(rImage, rDescription)):
            // CGImage has no structural equality; two loads of the same
            // asset are still considered equal states only when they
            // produced the exact same decoded image instance.
            lImage === rImage && lDescription == rDescription
        case let (.failure(lError, lDescription), .failure(rError, rDescription)):
            lError == rError && lDescription == rDescription
        default:
            false
        }
    }
}
