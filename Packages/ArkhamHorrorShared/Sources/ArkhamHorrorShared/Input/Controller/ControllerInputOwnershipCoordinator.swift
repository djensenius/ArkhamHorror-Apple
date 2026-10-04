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

    private var activeOwners: [ObjectIdentifier] = []

    func claim(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        activeOwners.removeAll { $0 == id }
        activeOwners.append(id)
    }

    func release(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        activeOwners.removeAll { $0 == id }
    }

    func canDispatch(for owner: AnyObject) -> Bool {
        activeOwners.last == ObjectIdentifier(owner)
    }
}
