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

    /// Every typed code, used to decode. Encoding goes through the exhaustive `rawValue`
    /// switch, so a new case cannot compile without a wire spelling.
    static let allKnown: [ArkhamDBErrorCode] = [
        .disabled, .oauthCallbackInvalidState, .notLinked, .tokenExpired, .notFound,
        .storageFailure, .remoteUnavailable, .oauthCompletionInvalid, .writeBackDisabled,
        .conflict, .pushUncertain, .validationFailed,
    ]

    /// The exact wire spelling. Unknown codes keep the server's spelling.
    var rawValue: String {
        switch self {
        case .disabled: "disabled"
        case .oauthCallbackInvalidState: "oauthCallbackInvalidState"
        case .notLinked: "notLinked"
        case .tokenExpired: "tokenExpired"
        case .notFound: "notFound"
        case .storageFailure: "storageFailure"
        case .remoteUnavailable: "remoteUnavailable"
        case .oauthCompletionInvalid: "oauthCompletionInvalid"
        case .writeBackDisabled: "writeBackDisabled"
        case .conflict: "conflict"
        case .pushUncertain: "pushUncertain"
        case .validationFailed: "validationFailed"
        case let .unknown(raw): raw
        }
    }

    init(rawValue: String) {
        self = Self.allKnown.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
    }

    init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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
