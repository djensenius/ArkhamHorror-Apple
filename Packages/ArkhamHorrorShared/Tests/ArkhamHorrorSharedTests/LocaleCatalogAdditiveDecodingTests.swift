@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Locale catalog additive decoding")
// swiftlint:disable:next type_body_length
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
            key: "label.test",
            variables: .object(["skill": .string("wild"), "count": Self.number("2")])
        ) == .success([
            .text("Test "), .semanticIcon(.skill(.wild)), .text(" ("), .text("2"), .text(")"),
        ]))
        #expect(resolver.render(
            key: "addToken", variables: .object(["token": .string("sealC")])
        ) == .success([
            .text("Add 1 "), .semanticIcon(.seal(.sealC)), .text(" chaos token."),
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

    @Test("Unknown entry variable roles fail only that entry")
    func unknownVariableRoleFailsPerEntry() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["story.ok", "story.future", "story.futureLink"],
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
        #expect(resolver.render(
            key: "story.futureLink", variables: .object(["target": .string("story.ok")])
        ) == .failure(.unsupportedEntry))
    }

    @Test("Malformed entry structure still fails the whole chunk")
    func malformedEntryStructureStillFailsChunk() throws {
        let cases = [
            Self.undeclaredVariableEntry,
            Self.presentationVariableNodeEntry,
            Self.malformedSiblingDeclEntry,
            Self.malformedLinkedVariablesEntry,
            Self.undeclaredUnknownRoleNodeEntry,
            Self.mismatchedUnknownRoleNodeEntry,
            Self.duplicateUnknownAndTextDeclEntry,
            Self.unknownRoleWithMalformedSiblingNodeEntry,
        ]
        for entry in cases {
            #expect(try Self.validateSingleEntry(entry) == .failure(.malformedChunk))
        }
    }

    @Test("Invalid unknown variable role grammar fails the whole chunk")
    func invalidUnknownVariableRoleGrammarFailsChunk() throws {
        let invalidRoles = ["", String(repeating: "a", count: 65), "future.icon"]
        for rawRole in invalidRoles {
            #expect(
                try Self.validateSingleEntry(Self.unknownRoleEntry(rawRole: rawRole))
                    == .failure(.malformedChunk)
            )
        }
    }

    @Test("Valid control entry validates successfully")
    func validControlEntryValidatesSuccessfully() throws {
        #expect(try Self.validateSingleEntry(Self.validControlEntry).isSuccess)
    }

    @Test("Valid unknown variable role still degrades only its entry")
    func validUnknownVariableRoleStillDegradesOnlyEntry() throws {
        let result = try Self.validateSingleEntry(Self.unknownRoleEntry(rawRole: "futureIcon"))
        guard case let .success(chunk) = result else {
            Issue.record("Expected a valid unknown role to degrade the entry")
            return
        }
        #expect(
            chunk.entries["story.entry"]
                == .unsupported(reason: "client-unsupported-additive-field")
        )
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
            #""unknownVariableTypes":[{"key":"label.future","variable":"token","#
                + #""role":7,"type":"x"}]"#,
            #""unknownVariableTypes":[{"key":"label.future","variable":"token","#
                + #""role":"text","type":"x","extra":true}]"#,
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
      },
      "story.futureLink": {
        "form": "message",
        "nodes": [
          {
            "type":"linked",
            "target":{"kind":"variable","name":"target","source":"named"},
            "modifier":null
          }
        ],
        "variables": [
          {"name": "target", "source": "named", "role": "futureLink"}
        ]
      }
    }
    """#

    private static let validControlEntry = #"""
    {
      "form": "message",
      "nodes": [{"type": "text", "value": "Valid"}],
      "variables": []
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

    private static let malformedSiblingDeclEntry = #"""
    {
      "form": "message",
      "nodes": [{"type": "text", "value": "Future"}],
      "variables": [
        {"name": "future", "source": "named", "role": "futureIcon"},
        {"name": "broken", "source": "named"}
      ]
    }
    """#

    private static let malformedLinkedVariablesEntry = #"""
    {
      "form": "message",
      "nodes": [{"type": "text", "value": "Future"}],
      "variables": [{"name": "future", "source": "named", "role": "futureIcon"}],
      "linkedVariables": [{"name": "linked", "source": 7, "role": "text"}]
    }
    """#

    private static let undeclaredUnknownRoleNodeEntry = #"""
    {
      "form": "message",
      "nodes": [{"type": "var", "name": "ghost", "source": "named", "role": "futureIcon"}],
      "variables": []
    }
    """#

    private static let mismatchedUnknownRoleNodeEntry = #"""
    {
      "form": "message",
      "nodes": [{"type": "var", "name": "token", "source": "named", "role": "futureIcon"}],
      "variables": [{"name": "token", "source": "named", "role": "futureOther"}]
    }
    """#

    private static let duplicateUnknownAndTextDeclEntry = #"""
    {
      "form": "message",
      "nodes": [{"type": "text", "value": "Duplicate"}],
      "variables": [
        {"name": "token", "source": "named", "role": "futureIcon"},
        {"name": "token", "source": "named", "role": "text"}
      ]
    }
    """#

    private static let unknownRoleWithMalformedSiblingNodeEntry = #"""
    {
      "form": "message",
      "nodes": [
        {"type": "var", "name": "token", "source": "named", "role": "futureIcon"},
        {"type": "break", "extra": true}
      ],
      "variables": [{"name": "token", "source": "named", "role": "futureIcon"}]
    }
    """#

    private static func unknownRoleEntry(rawRole: String) -> String {
        #"""
        {
          "form": "message",
          "nodes": [
            {"type": "var", "name": "token", "source": "named", "role": "\#(rawRole)"}
          ],
          "variables": [{"name": "token", "source": "named", "role": "\#(rawRole)"}]
        }
        """#
    }

    private static func validateSingleEntry(
        _ entry: String
    ) throws -> Result<LocaleCatalogChunk, LocaleCatalogFailure> {
        let chunk = """
        {"schemaVersion":"1.0.0","locale":"en","fallback":null,"pack":"story","entries":{
        "story.entry":\(entry)
        }}
        """
        let parsed = try Optional(LosslessJSONParser.parse(Data(chunk.utf8)))
        let value = try #require(parsed)
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
