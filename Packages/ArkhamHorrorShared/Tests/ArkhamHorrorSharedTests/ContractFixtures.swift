@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Shared loaders for the governed `Fixtures/Contract` bytes used by the schema drift suites,
/// plus the `Fixtures/LegacyContract` counterparts they compare against. The current pin lives in
/// `ContractPin.current`; this loader is deliberately revision-neutral so a repin needs no rename.
enum ContractFixtures {
    enum Failure: Error {
        case shape
        case missingRepresentative(String)
    }

    /// Governed `Fixtures/Contract` bytes (same as `contractData`). The 0.1.57 pre-repin drift
    /// copies in `Fixtures/Schema157Drift` were byte-identical to these and were removed when
    /// `Fixtures/Contract` was re-vendored.
    static func data(_ name: String) throws -> Data {
        try contractData(name)
    }

    static func value(_ name: String) throws -> JSONValue {
        try LosslessJSONParser.parse(data(name))
    }

    /// Legacy bytes captured before the 0.1.57 schema change (`<name>-pre-0.1.57.json`).
    static func legacyData(_ name: String) throws -> Data {
        try load("\(name)-pre-0.1.57", subdirectory: "Fixtures/LegacyContract")
    }

    static func legacyValue(_ name: String) throws -> JSONValue {
        try LosslessJSONParser.parse(legacyData(name))
    }

    static func contractData(_ name: String) throws -> Data {
        try load(name, subdirectory: "Fixtures/Contract")
    }

    static func representative(named name: String) throws -> JSONValue {
        guard case let .object(root) = try value("question-presentation-representatives"),
              case let .array(entries)? = root["presentations"]
        else { throw Failure.shape }
        for case let .object(entry) in entries where entry["name"] == .string(name) {
            if let presentation = entry["presentation"] {
                return presentation
            }
        }
        throw Failure.missingRepresentative(name)
    }

    static func prompt(
        rawQuestion: JSONValue,
        presentation: QuestionPresentation,
        binding: BoundQuestionPresentation
    ) -> BasicChoicePromptPresentation {
        BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: presentation.questionVersion,
                rawQuestion: rawQuestion,
                questionPresentation: presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: BasicChoiceParser.parseQuestion(rawQuestion),
            semanticPresentation: binding,
            semanticLocaleIdentifier: "en",
            cardCatalog: nil,
            choiceLabelResolutions: [:],
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private static func load(_ name: String, subdirectory: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: subdirectory
        ))
        return try Data(contentsOf: url)
    }
}
