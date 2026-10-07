import Foundation

struct PickDestinyAnswer: Sendable, Equatable, Codable {
    let contents: [QuestionPresentation.DestinyDrawing]

    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    init(contents: [QuestionPresentation.DestinyDrawing]) {
        self.contents = contents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        guard tag == "PickDestinyAnswer" else {
            throw DecodingError.dataCorruptedError(
                forKey: .tag,
                in: container,
                debugDescription: "Expected PickDestinyAnswer tag"
            )
        }
        contents = try container.decode(
            [QuestionPresentation.DestinyDrawing].self,
            forKey: .contents
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("PickDestinyAnswer", forKey: .tag)
        try container.encode(contents, forKey: .contents)
    }
}
