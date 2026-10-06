@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Locale catalog additive decoding")
struct LocaleCatalogAdditiveDecodingTests {
    @Test("Icon variables render closed chaos token and skill values")
    func iconVariablesRenderClosedValues() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["addToken", "label.test", "literal.icon", "label.pluralTokens"],
            chunkEntries: Self.iconVariableChunkEntries
        )
        let resolver = try await LocaleCatalogResolver(snapshot: documents.loadSnapshot())

        #expect(resolver.render(
            key: "addToken", variables: .object(["token": .string("elderThing")])
        ) == .success([
            .text("Add 1 "), .semanticIcon(.chaosToken(.elderThing)), .text(" chaos token."),
        ]))
        #expect(try resolver.render(
            key: "label.test",
            variables: .object(["skill": .string("combat"), "count": Self.number("3")])
        ) == .success([
            .text("Test "), .semanticIcon(.skill(.combat)), .text(" ("), .text("3"), .text(")"),
        ]))
        #expect(try resolver.render(
            key: "label.pluralTokens",
            variables: .object(["count": Self.number("2"), "token": .string("skull")])
        ) == .success([
            .text("Add "), .text("2"), .text(" "), .semanticIcon(.chaosToken(.skull)),
        ]))
        #expect(resolver.render(
            key: "addToken", variables: .object([:])
        ) == .failure(.missingVariable))
        #expect(resolver.render(
            key: "addToken", variables: .object(["token": .string("moon")])
        ) == .failure(.unsupportedVariableValue))
        #expect(resolver.render(
            key: "literal.icon", variables: .object([:])
        ) == .success([.icon("skull")]))
    }

    @Test("Icon variables accept exactly the governed token and skill tables")
    func iconVariableValueTable() {
        let tokenCases: [(String, StoryIcon)] = [
            ("skull", .chaosToken(.skull)),
            ("cultist", .chaosToken(.cultist)),
            ("tablet", .chaosToken(.tablet)),
            ("elderThing", .chaosToken(.elderThing)),
            ("autoFail", .chaosToken(.autoFail)),
            ("elderSign", .chaosToken(.elderSign)),
            ("curse", .chaosToken(.curse)),
            ("bless", .chaosToken(.bless)),
            ("frost", .chaosToken(.frost)),
            ("blood", .chaosToken(.blood)),
        ]
        let skillCases: [(String, StoryIcon)] = [
            ("willpower", .skill(.willpower)),
            ("intellect", .skill(.intellect)),
            ("combat", .skill(.combat)),
            ("agility", .skill(.agility)),
        ]
        for (raw, icon) in tokenCases + skillCases {
            #expect(StoryIcon.iconVariableValue(raw) == icon)
        }
        #expect(StoryIcon.iconVariableValue("elderthing") == nil)
        #expect(StoryIcon.iconVariableValue("wild") == nil)
    }

    @Test("Unknown entry variable roles fail only that entry")
    func unknownVariableRoleFailsPerEntry() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["story.ok", "story.future"],
            chunkEntries: Self.futureRoleChunkEntries
        )
        let snapshot = try await documents.loadSnapshot()
        let resolver = LocaleCatalogResolver(snapshot: snapshot)

        #expect(resolver.render(key: "story.ok", variables: .object([:])) == .success([
            .text("Still rendered"),
        ]))
        #expect(resolver.render(
            key: "story.future", variables: .object(["value": .string("skull")])
        ) == .failure(.unsupportedEntry))
    }

    @Test("Malformed entry structure still fails the whole chunk")
    func malformedEntryStructureStillFailsChunk() {
        let cases = [
            Self.undeclaredVariableEntry,
            Self.presentationVariableNodeEntry,
            Self.futureRoleWithMalformedSiblingDeclarationEntry,
            Self.futureRoleWithMalformedLinkedVariablesEntry,
        ]
        for entry in cases {
            #expect(Self.validateSingleEntry(entry) == .failure(.malformedChunk))
        }
    }

    @Test("Manifest unknownVariableTypes accepts iconVariable roles")
    func manifestAllowsIconVariableUnknownVariableTypeDiagnostics() throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let manifestText = try #require(String(data: documents.manifestBytes, encoding: .utf8))
        let diagnostic = #""unknownVariableTypes":[{"key":"label.future","#
            + #""variable":"token","role":"iconVariable","type":"futureToken"}]"#
        let withIconVariableDiagnostic = manifestText.replacingOccurrences(
            of: #""unknownVariableTypes":[]"#,
            with: diagnostic
        )
        let value = try LosslessJSONParser.parse(Data(withIconVariableDiagnostic.utf8))
        #expect(LocaleCatalogManifest.validate(value, against: documents.advertisement).isSuccess)
    }

    @Test("Malformed unknownVariableTypes diagnostics still reject the manifest")
    func malformedUnknownVariableTypeDiagnosticsRejectManifest() throws {
        let documents = try SyntheticLocaleCatalogDocuments.make()
        let manifestText = try #require(String(data: documents.manifestBytes, encoding: .utf8))
        let diagnostics = [
            #""unknownVariableTypes":[{"key":"label.future","variable":"token","role":7,"type":"x"}]"#,
            #""unknownVariableTypes":[{"key":"label.future","variable":"token","role":"text","type":"x","extra":true}]"#,
        ]
        for diagnostic in diagnostics {
            let manifest = manifestText.replacingOccurrences(
                of: #""unknownVariableTypes":[]"#,
                with: diagnostic
            )
            let value = try LosslessJSONParser.parse(Data(manifest.utf8))
            #expect(
                LocaleCatalogManifest.validate(value, against: documents.advertisement)
                    == .failure(.malformedManifest)
            )
        }
    }

    private static let iconVariableChunkEntries = #"""
    {
      "addToken": {
        "form": "message",
        "nodes": [
          {"type": "text", "value": "Add 1 "},
          {"type": "var", "name": "token", "source": "named", "role": "iconVariable"},
          {"type": "text", "value": " chaos token."}
        ],
        "variables": [{"name": "token", "source": "named", "role": "iconVariable"}]
      },
      "label.test": {
        "form": "message",
        "nodes": [
          {"type": "text", "value": "Test "},
          {"type": "var", "name": "skill", "source": "named", "role": "iconVariable"},
          {"type": "text", "value": " ("},
          {"type": "var", "name": "count", "source": "named", "role": "text"},
          {"type": "text", "value": ")"}
        ],
        "variables": [
          {"name": "skill", "source": "named", "role": "iconVariable"},
          {"name": "count", "source": "named", "role": "text"}
        ]
      },
      "label.pluralTokens": {
        "form": "plural",
        "cases": [
          [
            {"type": "text", "value": "Add 1 "},
            {"type": "var", "name": "token", "source": "named", "role": "iconVariable"}
          ],
          [
            {"type": "text", "value": "Add "},
            {"type": "var", "name": "count", "source": "named", "role": "text"},
            {"type": "text", "value": " "},
            {"type": "var", "name": "token", "source": "named", "role": "iconVariable"}
          ]
        ],
        "variables": [
          {"name": "count", "source": "named", "role": "text"},
          {"name": "token", "source": "named", "role": "iconVariable"}
        ]
      },
      "literal.icon": {
        "form": "message",
        "nodes": [{"type": "var", "name": "skull", "source": "named", "role": "icon"}],
        "variables": [{"name": "skull", "source": "named", "role": "icon"}]
      }
    }
    """#

    private static let futureRoleChunkEntries = #"""
    {
      "story.ok": {
        "form": "message",
        "nodes": [{"type": "text", "value": "Still rendered"}],
        "variables": []
      },
      "story.future": {
        "form": "message",
        "nodes": [
          {"type": "var", "name": "value", "source": "named", "role": "futureIcon"}
        ],
        "variables": [
          {"name": "value", "source": "named", "role": "futureIcon"}
        ]
      }
    }
    """#

    private static let undeclaredVariableEntry = #"""
    {
      "form": "message",
      "nodes": [{"type": "var", "name": "missing", "source": "named", "role": "text"}],
      "variables": []
    }
    """#

    private static let presentationVariableNodeEntry = #"""
    {
      "form": "message",
      "nodes": [{"type": "var", "name": "style", "source": "named", "role": "presentation"}],
      "variables": [{"name": "style", "source": "named", "role": "presentation"}]
    }
    """#

    private static let futureRoleWithMalformedSiblingDeclarationEntry = #"""
    {
      "form": "message",
      "nodes": [{"type": "text", "value": "Future"}],
      "variables": [
        {"name": "future", "source": "named", "role": "futureIcon"},
        {"name": "broken", "source": "named"}
      ]
    }
    """#

    private static let futureRoleWithMalformedLinkedVariablesEntry = #"""
    {
      "form": "message",
      "nodes": [{"type": "text", "value": "Future"}],
      "variables": [{"name": "future", "source": "named", "role": "futureIcon"}],
      "linkedVariables": [{"name": "linked", "source": 7, "role": "text"}]
    }
    """#

    private static func validateSingleEntry(
        _ entry: String
    ) -> Result<LocaleCatalogChunk, LocaleCatalogFailure> {
        let chunk = """
        {"schemaVersion":"1.0.0","locale":"en","fallback":null,"pack":"story","entries":{
        "story.entry":\(entry)
        }}
        """
        let value = try? LosslessJSONParser.parse(Data(chunk.utf8))
        guard let value else { return .failure(.malformedChunk) }
        return LocaleCatalogChunk.validate(
            value,
            expectedLocale: "en",
            expectedFallback: nil,
            expectedPack: "story",
            expectedKeys: 1,
            expectedUnsupportedKeys: 0
        )
    }

    private static func number(_ text: String) throws -> JSONValue {
        try .number(JSONNumber(exactDecimalLiteral: text))
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }
}
