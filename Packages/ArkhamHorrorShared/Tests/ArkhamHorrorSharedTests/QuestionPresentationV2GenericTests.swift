@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Question presentation v2 generic contract")
struct QuestionPresentationV2GenericTests {
    private let genericNames = [
        "choose-amounts",
        "choose-deck",
        "choose-n",
        "choose-some",
        "choose-up-to-n",
        "cost-ability-window",
        "invalid-info",
        "one-at-a-time-auto",
        "one-from-each",
        "payment-amounts",
        "read",
        "skill-label",
        "wrapped",
    ]

    @Test("Every vendored generic v2 presentation decodes and binds structurally")
    func genericFixturesDecodeAndBind() throws {
        for name in genericNames {
            let presentation = try presentationFixture("question-presentation-generic-\(name)")
            #expect(presentation.protocolVersion == 2)
            #expect(presentation.isGenericallyRenderable)
            let binding = try presentation.bind(
                to: rawFixture("question-generic-\(name)"),
                expectedQuestionVersion: presentation.questionVersion
            )
            #expect(binding.rawChoices.count == presentation.choiceCount)
            #expect(Set(presentation.choices.map(\.sourceIndex)) == Set(0..<presentation.choiceCount))
        }
    }

    @Test("Every representative v2 presentation entry decodes")
    func representativeFixturesDecode() throws {
        struct Representatives: Decodable {
            struct Entry: Decodable {
                let name: String
                let presentation: QuestionPresentation
            }
            let presentations: [Entry]
        }
        let representatives = try ContractJSON.decode(
            Representatives.self,
            from: fixture("question-presentation-representatives")
        )
        #expect(representatives.presentations.count == 37)
        for entry in representatives.presentations {
            #expect(entry.presentation.protocolVersion == 2, "\(entry.name)")
            #expect(entry.presentation.isGenericallyRenderable, "\(entry.name)")
        }
    }

    @Test("V2 structural mutations reject")
    func structuralMutationsReject() throws {
        let base = try JSONValueMutationObject(
            fixtureData: fixture("question-presentation-generic-choose-n")
        )
        let mutations: [(String, JSONValue?)] = [
            ("/protocolVersion", .number(.integer(1))),
            ("/questionKind", .string("future")),
            ("/extra", .bool(true)),
            ("/choices/0/kind", .string("future")),
            ("/choices/0/sourceIndex", .number(.integer(1))),
            ("/choices/1/sourceIndex", .number(.integer(3))),
            ("/choiceCount", .number(.integer(3))),
        ]
        for (pointer, value) in mutations {
            #expect(throws: DecodingError.self, "\(pointer)") {
                try ContractJSON.decode(
                    QuestionPresentation.self,
                    from: base.replacing(pointer: pointer, with: value).data()
                )
            }
        }
    }

    private func presentationFixture(_ name: String) throws -> QuestionPresentation {
        try ContractJSON.decode(QuestionPresentation.self, from: fixture(name))
    }

    private func rawFixture(_ name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixture(name))
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }
}

private struct JSONValueMutationObject {
    private let original: JSONValue

    init(fixtureData: Data) throws {
        original = try ContractJSON.decode(JSONValue.self, from: fixtureData)
    }

    func replacing(pointer: String, with value: JSONValue?) throws -> Self {
        var copy = original
        try copy.replace(pointer: pointer, with: value)
        return Self(original: copy)
    }

    func data() throws -> Data {
        try ContractJSON.encode(original)
    }

    private init(original: JSONValue) {
        self.original = original
    }
}

private extension JSONValue {
    mutating func replace(pointer: String, with value: JSONValue?) throws {
        var parts = pointer.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "" else { throw MutationError.invalidPointer }
        parts.removeFirst()
        try replace(parts: parts, with: value)
    }

    mutating func replace(parts: [String], with value: JSONValue?) throws {
        guard let head = parts.first else { throw MutationError.invalidPointer }
        if parts.count == 1 {
            switch self {
            case var .object(object):
                object[head] = value
                self = .object(object)
            case var .array(array):
                guard let index = Int(head), array.indices.contains(index), let value else {
                    throw MutationError.invalidPointer
                }
                array[index] = value
                self = .array(array)
            default:
                throw MutationError.invalidPointer
            }
            return
        }
        switch self {
        case var .object(object):
            guard var child = object[head] else { throw MutationError.invalidPointer }
            try child.replace(parts: Array(parts.dropFirst()), with: value)
            object[head] = child
            self = .object(object)
        case var .array(array):
            guard let index = Int(head), array.indices.contains(index) else {
                throw MutationError.invalidPointer
            }
            var child = array[index]
            try child.replace(parts: Array(parts.dropFirst()), with: value)
            array[index] = child
            self = .array(array)
        default:
            throw MutationError.invalidPointer
        }
    }
}

private enum MutationError: Error {
    case invalidPointer
}
