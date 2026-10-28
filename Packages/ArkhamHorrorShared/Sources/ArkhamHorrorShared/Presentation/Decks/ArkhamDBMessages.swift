import Foundation

func arkhamDBLocalized(_ suffix: String) -> String {
    NSLocalizedString("arkhamdb.\(suffix)", bundle: .module, comment: "")
}

func arkhamDBErrorMessage(_ error: ArkhamDBError?) -> String {
    if error?.requiresRelinking == true {
        return arkhamDBLocalized("relinkRequired")
    }
    if error?.code == .disabled {
        return arkhamDBLocalized("disabled")
    }
    if error?.code == .remoteUnavailable {
        return arkhamDBLocalized("remoteUnavailable")
    }
    return arkhamDBLocalized("failed")
}
