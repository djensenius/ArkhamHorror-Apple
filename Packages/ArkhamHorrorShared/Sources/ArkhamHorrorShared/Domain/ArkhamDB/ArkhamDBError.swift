/// Governed ArkhamDB endpoint error codes, independent of app session authentication.
enum ArkhamDBErrorCode: Sendable, Hashable, Codable {
    case disabled
    case oauthCallbackInvalidState
    case notLinked
    case tokenExpired
    case notFound
    case storageFailure
    case remoteUnavailable
    case oauthCompletionInvalid
    case writeBackDisabled
    case conflict
    case pushUncertain
    case validationFailed
    case unknown(String)

    /// Known wire spellings; a table keeps the mapping flat as the contract grows.
    private static let knownCodes: [String: ArkhamDBErrorCode] = [
        "disabled": .disabled,
        "oauthCallbackInvalidState": .oauthCallbackInvalidState,
        "notLinked": .notLinked,
        "tokenExpired": .tokenExpired,
        "notFound": .notFound,
        "storageFailure": .storageFailure,
        "remoteUnavailable": .remoteUnavailable,
        "oauthCompletionInvalid": .oauthCompletionInvalid,
        "writeBackDisabled": .writeBackDisabled,
        "conflict": .conflict,
        "pushUncertain": .pushUncertain,
        "validationFailed": .validationFailed,
    ]

    private static let rawValues = Dictionary(
        uniqueKeysWithValues: knownCodes.map { ($0.value, $0.key) }
    )

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownCodes[raw] ?? .unknown(raw)
    }

    func encode(to encoder: any Encoder) throws {
        let raw: String = if case let .unknown(raw) = self {
            raw
        } else {
            Self.rawValues[self] ?? ""
        }
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
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
