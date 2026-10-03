@testable import ArkhamHorrorShared
import Testing

@MainActor
@Suite("Controller input ownership")
struct ControllerInputOwnershipCoordinatorTests {
    private final class OwnerToken {}

    @Test("Only the current input owner may dispatch controller events")
    func onlyCurrentOwnerMayDispatchControllerEvents() {
        let coordinator = ControllerInputOwnershipCoordinator()
        let firstBoard = OwnerToken()
        let secondBoard = OwnerToken()

        coordinator.claim(firstBoard)
        #expect(coordinator.canDispatch(for: firstBoard))
        #expect(!coordinator.canDispatch(for: secondBoard))

        coordinator.claim(secondBoard)
        #expect(!coordinator.canDispatch(for: firstBoard))
        #expect(coordinator.canDispatch(for: secondBoard))

        coordinator.release(firstBoard)
        #expect(coordinator.canDispatch(for: secondBoard))

        coordinator.release(secondBoard)
        #expect(!coordinator.canDispatch(for: firstBoard))
        #expect(!coordinator.canDispatch(for: secondBoard))
    }
}
