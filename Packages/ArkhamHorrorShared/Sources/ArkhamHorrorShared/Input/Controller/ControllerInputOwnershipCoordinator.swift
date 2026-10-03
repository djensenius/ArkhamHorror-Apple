import Foundation

/// Process-local ownership gate for physical game-controller input.
///
/// A single `GCController` button press is fanned out to every live
/// ``GameControllerDiscovery`` subscription. Board windows still own independent
/// ``BoardCommandController`` instances, but only the most recently claimed input owner may
/// consume those controller events, so one physical press can never submit choices in two
/// visible games.
@MainActor
final class ControllerInputOwnershipCoordinator {
    static let shared = ControllerInputOwnershipCoordinator()

    private var currentOwner: ObjectIdentifier?

    func claim(_ owner: AnyObject) {
        currentOwner = ObjectIdentifier(owner)
    }

    func release(_ owner: AnyObject) {
        guard currentOwner == ObjectIdentifier(owner) else { return }
        currentOwner = nil
    }

    func canDispatch(for owner: AnyObject) -> Bool {
        currentOwner == ObjectIdentifier(owner)
    }
}
