@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Locale catalog additive decoding")
struct LocaleCatalogAdditiveDecodingTests {
    @Test("Icon variables render closed chaos token and skill values")
    func iconVariablesRenderClosedValues() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["addToken", "label.test", "literal.icon"],
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

    private static func number(_ text: String) throws -> JSONValue {
        try .number(JSONNumber(exactDecimalLiteral: text))
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
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }
}
