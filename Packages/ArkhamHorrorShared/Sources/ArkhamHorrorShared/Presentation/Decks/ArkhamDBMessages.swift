import Foundation

func arkhamDBLocalized(_ suffix: String) -> String {
    NSLocalizedString("arkhamdb.\(suffix)", bundle: .module, comment: "")
}

func arkhamDBLinkErrorMessage(_ error: ArkhamDBLinkFlowError?) -> String {
    switch error {
    case .denied: arkhamDBLocalized("denied")
    case .presentationUnavailable: arkhamDBLocalized("presentationUnavailable")
    default: arkhamDBLocalized("failed")
    }
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

func arkhamDBSkippedText(_ count: Int) -> String {
    String(format: arkhamDBLocalized(count == 1 ? "skippedOne" : "skipped"), count)
}

func arkhamDBUpdatedText(_ value: String?) -> String? {
    guard let value else { return nil }
    let date = (try? Date(value, strategy: .iso8601))
        ?? (try? Date(value, strategy: .iso8601.time(includingFractionalSeconds: true)))
    guard let date else { return nil }
    return String(
        format: arkhamDBLocalized("updated"),
        date.formatted(date: .abbreviated, time: .shortened)
    )
}
