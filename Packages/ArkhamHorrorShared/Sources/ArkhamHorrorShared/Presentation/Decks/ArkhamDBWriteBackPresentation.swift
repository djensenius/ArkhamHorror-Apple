import Foundation

// Presentation rules for schema 0.1.55 write-back, derived from the server's
// `canResolvePush`, `accountingFencedPush` and the contract README (task-2.45).

extension ArkhamDBWriteBackConflictReason {
    /// Resolutions the server can accept for this reason. Overwrite is refused (HTTP 409)
    /// for campaignChanged, an uncertain creation and an already created target, and
    /// every resolution is refused for the accounting fences. Unknown reasons offer
    /// nothing rather than guessing.
    var allowedResolutions: [ArkhamDBWriteBackResolution] {
        switch self {
        case .remoteChanged: [.keepRemote, .overwrite, .saveAsNew]
        case .campaignChanged, .pushUncertain, .targetAlreadyLinked: [.keepRemote, .saveAsNew]
        case .boundaryUndone, .accountChanged, .unknown: []
        }
    }

    /// Durable accounting fences: retry is a no-op, every resolution is refused and no
    /// reconciliation API exists. They survive toggles and block later pushes.
    var isBlocked: Bool {
        self == .boundaryUndone || self == .accountChanged
    }

    var messageKey: String {
        switch self {
        case .remoteChanged: "writeBack.reason.remoteChanged"
        case .campaignChanged: "writeBack.reason.campaignChanged"
        case .pushUncertain: "writeBack.reason.pushUncertain"
        case .targetAlreadyLinked: "writeBack.reason.targetAlreadyLinked"
        case .boundaryUndone: "writeBack.reason.boundaryUndone"
        case .accountChanged: "writeBack.reason.accountChanged"
        case .unknown: "writeBack.reason.unknown"
        }
    }
}

extension ArkhamDBWriteBackResolution {
    var titleKey: String {
        "writeBack.resolution.\(rawValue)"
    }

    /// Honest consequences, shown in the sheet and the confirmation dialog.
    var explanationKey: String {
        "writeBack.resolution.\(rawValue).explanation"
    }

    var confirmationTitleKey: String {
        "writeBack.resolution.\(rawValue).confirmation"
    }
}

extension ArkhamDBWriteBackStatus {
    var blockedReason: ArkhamDBWriteBackConflictReason? {
        guard state == .conflict, let reason = conflict?.reason, reason.isBlocked else {
            return nil
        }
        return reason
    }

    /// The server requires the deck to be opted in for retry and resolution. A
    /// `validationFailed` push (campaign-identity fence or unsupported cards) is not
    /// repaired by retrying the same snapshot, so Retry is not offered for it.
    var canRetry: Bool {
        enabled && state == .failed && error != "validationFailed"
    }

    /// Unknown future states offer nothing, even when they carry a conflict object.
    /// Failed creation intents (`pushUncertain`, or `writeBackDisabled` retained by
    /// opting out) block later snapshots; the server reconciles them with retry,
    /// keep-remote or save-as-new (`canResolvePush` accepts `failed`). Overwrite is
    /// never offered there because the server refuses it for creation intents.
    /// Overwrite for remoteChanged may still be refused for hidden creation lineage; the
    /// 409 `conflict` path then shows a specific message and refreshes status.
    var allowedResolutions: [ArkhamDBWriteBackResolution] {
        guard enabled else { return [] }
        switch state {
        case .conflict:
            return conflict?.reason.allowedResolutions ?? []
        case .failed where error == "pushUncertain" || error == "writeBackDisabled":
            return [.keepRemote, .saveAsNew]
        default:
            return []
        }
    }

    /// Whether the row offers the resolution sheet (conflicts are always viewable).
    var opensResolution: Bool {
        state == .conflict || !allowedResolutions.isEmpty
    }

    var statusText: String {
        if let reason = conflict?.reason, state == .conflict {
            return arkhamDBLocalized(reason.messageKey)
        }
        switch state {
        case .idle:
            return arkhamDBLocalized(enabled ? "writeBack.state.idle" : "writeBack.state.off")
        case .pending: return arkhamDBLocalized("writeBack.state.pending")
        case .running: return arkhamDBLocalized("writeBack.state.running")
        case .failed:
            // `error` is a server error code for failures; only known codes pick copy.
            switch error {
            case "pushUncertain": return arkhamDBLocalized("writeBack.state.failedUncertain")
            case "writeBackDisabled": return arkhamDBLocalized("writeBack.state.failedDisabled")
            case "validationFailed": return arkhamDBLocalized("writeBack.state.failedValidation")
            default: return arkhamDBLocalized("writeBack.state.failed")
            }
        case .succeeded: return arkhamDBLocalized("writeBack.state.succeeded")
        case .cancelled: return arkhamDBLocalized("writeBack.state.cancelled")
        case .conflict, .unknown: return arkhamDBLocalized("writeBack.state.unknown")
        }
    }

    /// Spent XP is never synchronized; say so whenever this deck can be pushed. The
    /// contract fixes `spentXpSynced` to false, so a true value is not trusted to hide it.
    var showsSpentXpNote: Bool {
        enabled
    }
}

func arkhamDBSkippedWriteBackText(_ count: Int) -> String {
    String(
        format: arkhamDBLocalized(count == 1 ? "writeBack.skippedOne" : "writeBack.skipped"),
        count
    )
}
