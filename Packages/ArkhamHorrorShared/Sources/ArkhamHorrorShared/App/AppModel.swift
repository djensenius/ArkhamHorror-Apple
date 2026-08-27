import Observation

@MainActor
@Observable
final class AppModel {
    var serverStatus: ServerStatus
    private(set) var lastCommand: AppCommand?
    private(set) var message: String

    init(serverStatus: ServerStatus = .notConfigured) {
        self.serverStatus = serverStatus
        message = "Use the standard focus system to choose an action."
    }

    func send(_ command: AppCommand) {
        lastCommand = command

        switch command {
        case .openServerConfiguration:
            message = "Server configuration arrives after the foundation phase."
        case .beginNewCampaign:
            message = "Game setup is intentionally not part of Phase 0."
        }
    }
}
