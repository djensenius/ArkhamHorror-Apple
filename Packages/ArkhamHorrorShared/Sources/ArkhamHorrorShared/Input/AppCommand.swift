enum AppCommand: Equatable, Sendable {
    case openServerConfiguration
    case beginNewCampaign
}

enum AppCommandTarget: Hashable, Sendable {
    case serverStatus
    case primaryAction

    var command: AppCommand {
        switch self {
        case .serverStatus:
            .openServerConfiguration
        case .primaryAction:
            .beginNewCampaign
        }
    }
}
