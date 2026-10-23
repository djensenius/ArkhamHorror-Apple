/// Governed ArkhamDB endpoint error codes, independent of app session authentication.
enum ArkhamDBErrorCode: String, Sendable, Codable, CaseIterable {
    case disabled
    case oauthCallbackInvalidState
    case notLinked
    case tokenExpired
    case notFound
    case storageFailure
    case remoteUnavailable
    case oauthCompletionInvalid
}

/// An ArkhamDB operation failure. HTTP 409 `notLinked` and `tokenExpired` require
/// linking/relinking the remote account, not expiring the app's still-valid session.
struct ArkhamDBError: Error, Sendable, Equatable, Codable {
    let code: ArkhamDBErrorCode
    let error: String

    var requiresRelinking: Bool {
        code == .notLinked || code == .tokenExpired
    }
}
