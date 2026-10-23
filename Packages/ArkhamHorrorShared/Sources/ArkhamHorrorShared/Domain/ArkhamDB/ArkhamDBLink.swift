/// Authorization browser URL and expiry returned by `POST /arkham/arkhamdb/link/start`.
struct ArkhamDBLinkStartResponse: Sendable, Equatable, Codable {
    let authorizeUrl: String
    let expiresAt: String
}

/// A single-use completion secret, not an ArkhamDB access token or app session token.
enum ArkhamDBCompletionSecretTag: Sendable {}
typealias ArkhamDBCompletionSecret = NonEmptyString<ArkhamDBCompletionSecretTag>

struct ArkhamDBLinkCompletionRequest: Sendable, Equatable, Codable {
    let completion: ArkhamDBCompletionSecret
}

/// Completion returns an empty JSON array, not a status object; refresh status afterwards.
struct ArkhamDBLinkCompletionResponse: Sendable, Equatable {}

extension ArkhamDBLinkCompletionResponse: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.unkeyedContainer()
        guard container.isAtEnd else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected an empty array for ArkhamDB link completion"
            ))
        }
    }

    func encode(to encoder: any Encoder) throws {
        _ = encoder.unkeyedContainer()
    }
}

extension ServerCompatibility {
    static let arkhamDBAccountLinkingCapability = "arkhamdb.account-linking.v1"

    /// The feature is opt-in per deployment, never inferred from the schema revision.
    var supportsArkhamDBAccountLinking: Bool {
        modernCapabilities.contains(Self.arkhamDBAccountLinkingCapability)
    }
}
