import Foundation

struct CampaignSpecificAnswer: Sendable, Equatable, Codable {
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
        guard tag == "CampaignSpecificAnswer" else {
            throw DecodingError.dataCorruptedError(
                forKey: .tag,
                in: container,
                debugDescription: "Expected CampaignSpecificAnswer tag"
            )
        }
        contents = try container.decode(JSONValue.self, forKey: .contents)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("CampaignSpecificAnswer", forKey: .tag)
        try container.encode(contents, forKey: .contents)
    }
}
