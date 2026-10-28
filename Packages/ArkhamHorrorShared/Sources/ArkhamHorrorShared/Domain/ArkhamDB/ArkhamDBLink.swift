import Foundation

/// Authorization browser URL and expiry returned by `POST /arkham/arkhamdb/link/start`.
struct ArkhamDBLinkStartResponse: Sendable, Equatable, Codable {
    let authorizeUrl: String
    let expiresAt: String
}

/// A single-use completion secret, not an ArkhamDB access token or app session token.
struct ArkhamDBCompletionSecret: Sendable, Equatable, Codable {
    let rawValue: String

    init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else { throw NonEmptyStringError.empty }
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ArkhamDBCompletionSecret: CustomStringConvertible, CustomReflectable {
    var description: String {
        "[redacted]"
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

extension ArkhamDBCompletionSecret: CustomDebugStringConvertible {
    var debugDescription: String {
        description
    }
}

struct ArkhamDBLinkCompletionRequest: Sendable, Equatable, Codable {
    let completion: ArkhamDBCompletionSecret
}

extension ArkhamDBLinkCompletionRequest: CustomStringConvertible, CustomReflectable {
    var description: String {
        "ArkhamDBLinkCompletionRequest([redacted])"
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

extension ArkhamDBLinkCompletionRequest: CustomDebugStringConvertible {
    var debugDescription: String {
        description
    }
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
