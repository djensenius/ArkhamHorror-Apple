import Foundation

/// Top-level answer envelope accepted by the backend only for `ContinueCampaign` prompts
/// (see `Entity/Answer.hs`). The `contents` value is the server-provided campaign step
/// copied from the current snapshot; the native client never synthesizes a plain
/// continuation step client-side.
struct CampaignStepAnswer: Sendable, Equatable, Codable {
    let contents: JSONValue

    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    init(contents: JSONValue) {
        self.contents = contents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        guard tag == "CampaignStepAnswer" else {
            throw DecodingError.dataCorruptedError(
                forKey: .tag,
                in: container,
                debugDescription: "Expected CampaignStepAnswer tag"
            )
        }
        contents = try container.decode(JSONValue.self, forKey: .contents)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("CampaignStepAnswer", forKey: .tag)
        try container.encode(contents, forKey: .contents)
    }
}
