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
    case unknown(String)

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = switch raw {
        case "disabled": .disabled
        case "oauthCallbackInvalidState": .oauthCallbackInvalidState
        case "notLinked": .notLinked
        case "tokenExpired": .tokenExpired
        case "notFound": .notFound
        case "storageFailure": .storageFailure
        case "remoteUnavailable": .remoteUnavailable
        case "oauthCompletionInvalid": .oauthCompletionInvalid
        default: .unknown(raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        let raw: String = switch self {
        case .disabled: "disabled"
        case .oauthCallbackInvalidState: "oauthCallbackInvalidState"
        case .notLinked: "notLinked"
        case .tokenExpired: "tokenExpired"
        case .notFound: "notFound"
        case .storageFailure: "storageFailure"
        case .remoteUnavailable: "remoteUnavailable"
        case .oauthCompletionInvalid: "oauthCompletionInvalid"
        case let .unknown(raw): raw
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
