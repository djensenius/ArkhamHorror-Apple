@testable import ArkhamHorrorShared
import Foundation
import Testing

/// TASK-1.2.23: `cardNameVar` / `investigatorNameVar` labels swap the server's English name
/// for the catalog's `cardNames.<code>`, like the web's `handleI18n`. The card names come from
/// the vendored 0.1.63 en/de/pl `cardNames` packs; the label entries are synthetic (see
/// `Fixtures/LegacyContract/PROVENANCE.md`).
@Suite("Label card name substitution")
struct LabelCardNameSubstitutionTests {
    private static let syntheticEnglishLabels = """
    {"label.discardName":{"form":"message","nodes":[{"type":"text","value":"Discard "},\
    {"type":"var","name":"name","source":"named","role":"text"}],\
    "variables":[{"name":"name","source":"named","role":"text"}]},\
    "drew":{"form":"message","nodes":[\
    {"type":"var","name":"iname","source":"named","role":"text"},\
    {"type":"text","value":" drew "},\
    {"type":"var","name":"name","source":"named","role":"text"}],\
    "variables":[{"name":"iname","source":"named","role":"text"},\
    {"name":"name","source":"named","role":"text"}]},\
    "cardNames.90001":{"form":"message","nodes":[\
    {"type":"text","value":"Synthetic English Only"}],"variables":[]}}
    """

    private static let syntheticGermanLabels = """
    {"label.discardName":{"form":"message","nodes":[\
    {"type":"var","name":"name","source":"named","role":"text"},\
    {"type":"text","value":" ablegen"}],\
    "variables":[{"name":"name","source":"named","role":"text"}]},\
    "drew":{"form":"message","nodes":[\
    {"type":"var","name":"iname","source":"named","role":"text"},\
    {"type":"text","value":" zog "},\
    {"type":"var","name":"name","source":"named","role":"text"}],\
    "variables":[{"name":"iname","source":"named","role":"text"},\
    {"name":"name","source":"named","role":"text"}]}}
    """

    private static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json",
            subdirectory: "Fixtures/LocaleCatalog/Contract"
        ))
        return try Data(contentsOf: url)
    }

    private static func syntheticChunk(
        locale: String, fallback: String?, entries: String, keys: Int
    ) throws -> LocaleCatalogChunk {
        let fallbackJSON = fallback.map { "\"\($0)\"" } ?? "null"
        let bytes = Data("""
        {"schemaVersion":"1.0.0","locale":"\(locale)","fallback":\(fallbackJSON),\
        "pack":"syntheticLabels","entries":\(entries)}
        """.utf8)
        return try LocaleCatalogChunk.validate(
            LosslessJSONParser.parse(bytes), expectedLocale: locale,
            expectedFallback: fallback, expectedPack: "syntheticLabels",
            expectedKeys: keys, expectedUnsupportedKeys: 0
        ).get()
    }

    /// The vendored 0.1.63 manifest and every vendored chunk on `locale`'s chain, plus the
    /// synthetic label chunks.
    private static func resolver(locale: String) throws -> LocaleCatalogResolver {
        let capabilities = try ContractJSON.decode(
            ServerCapabilities.self, from: fixture("capabilities-locale-catalog")
        )
        let advertisement = try #require(capabilities.localeCatalog)
        let manifestBytes = try fixture("locale-catalog-manifest")
        let manifest = try LocaleCatalogManifest.validate(
            LosslessJSONParser.parse(manifestBytes), against: advertisement
        ).get()
        var chunks: [LocaleCatalogChunkKey: LocaleCatalogChunk] = [:]
        for chainLocale in manifest.localeChain(from: locale) {
            let record = try #require(manifest.record(for: chainLocale))
            for descriptor in record.chunks {
                chunks[LocaleCatalogChunkKey(locale: chainLocale, pack: descriptor.pack)] =
                    try LocaleCatalogChunk.validate(
                        LosslessJSONParser.parse(
                            fixture("locale-catalog-chunk-\(descriptor.sha256)")
                        ),
                        expectedLocale: chainLocale, expectedFallback: record.fallback,
                        expectedPack: descriptor.pack, expectedKeys: descriptor.keys,
                        expectedUnsupportedKeys: descriptor.unsupportedKeys
                    ).get()
            }
        }
        chunks[LocaleCatalogChunkKey(locale: "en", pack: "syntheticLabels")] =
            try syntheticChunk(
                locale: "en", fallback: nil, entries: syntheticEnglishLabels, keys: 3
            )
        chunks[LocaleCatalogChunkKey(locale: "de", pack: "syntheticLabels")] =
            try syntheticChunk(
                locale: "de", fallback: "en", entries: syntheticGermanLabels, keys: 2
            )
        return try LocaleCatalogResolver(snapshot: LocaleCatalogSnapshot(
            identity: LocaleCatalogIdentity(
                endpoint: #require(URL(
                    string: "https://catalog.example.test/locale-catalog/manifest.json"
                )),
                catalogRevision: advertisement.catalogRevision,
                locale: locale,
                manifestSha256: advertisement.manifestSha256
            ),
            manifest: manifest,
            chunks: chunks
        ))
    }

    private static func label(
        _ wire: String, locale: String
    ) throws -> Result<String, StoryUnavailableReason> {
        try StoryNarrativeLocalization.resolveProductionChoiceLabel(
            wire, resolver: resolver(locale: locale),
            catalogUnavailability: .catalog(.transportFailure)
        )
    }

    /// `cardNameVar` on Swarm of Rats (01159), as `Arkham/I18n.hs` `varStr` encodes it.
    private static let discardSwarm =
        #"$label.discardName __name=s:"01159" name=s:"Swarm of Rats""#
    /// `cardNameVar` + `investigatorNameVar`, as `Arkham/Game/Runner.hs` `DrewPlayerEnemy`.
    private static let skidsDrewSwarm = #"$drew __iname=s:"01003" __name=s:"01159" "#
        + #"iname=s:"\"Skids\" O'Toole" name=s:"Swarm of Rats""#

    @Test("name is replaced with the selected locale's card name")
    func substitutesName() throws {
        #expect(try Self.label(Self.discardSwarm, locale: "en")
            == .success("Discard Swarm of Rats"))
        #expect(try Self.label(Self.discardSwarm, locale: "de")
            == .success("Rattenschwarm ablegen"))
        // pl is card-only: the label text falls back to en, the card name stays Polish.
        #expect(try Self.label(Self.discardSwarm, locale: "pl")
            == .success("Discard Rój szczurów"))
    }

    @Test("iname is replaced with the selected locale's investigator name")
    func substitutesInvestigatorName() throws {
        #expect(try Self.label(Self.skidsDrewSwarm, locale: "en")
            == .success("\"Skids\" O'Toole drew Swarm of Rats"))
        #expect(try Self.label(Self.skidsDrewSwarm, locale: "de")
            == .success("„Skids“ O’Toole zog Rattenschwarm"))
        #expect(try Self.label(Self.skidsDrewSwarm, locale: "pl")
            == .success("\"Ślizg\" O'Toole drew Rój szczurów"))
    }

    @Test("Without __name, or with an empty name or code, the server name is kept")
    func keepsServerNameWithoutBothVariables() throws {
        #expect(try Self.label(#"$label.discardName name=s:"Swarm of Rats""#, locale: "de")
            == .success("Swarm of Rats ablegen"))
        #expect(try Self.label(
            #"$label.discardName __name=s:"" name=s:"Swarm of Rats""#, locale: "de"
        ) == .success("Swarm of Rats ablegen"))
        #expect(try Self.label(
            #"$label.discardName __name=s:"01159" name=s:"""#, locale: "de"
        ) == .success("ablegen"))
        #expect(try Self.label(
            #"$drew __name=s:"01159" iname=s:"Roland Banks" name=s:"Swarm of Rats""#,
            locale: "pl"
        ) == .success("Roland Banks drew Rój szczurów"))
    }

    @Test("A code missing from the locale's pack falls back to en, then to the server name")
    func missingCodeFallsBack() throws {
        #expect(try Self.label(
            #"$label.discardName __name=s:"90001" name=s:"Server Name""#, locale: "de"
        ) == .success("Synthetic English Only ablegen"))
        #expect(try Self.label(
            #"$label.discardName __name=s:"99999" name=s:"Server Name""#, locale: "de"
        ) == .success("Server Name ablegen"))
        #expect(try Self.label(
            #"$label.discardName __name=s:"99999" name=s:"Server Name""#, locale: "pl"
        ) == .success("Discard Server Name"))
    }

    @Test("An unresolved label key still fails closed")
    func unresolvedKeyFailsClosed() throws {
        let substituted = try Self.label(
            #"$label.noSuchLabel __name=s:"01159" name=s:"Swarm of Rats""#, locale: "de"
        )
        let plain = try Self.label(#"$label.noSuchLabel name=s:"Swarm of Rats""#, locale: "de")
        #expect(substituted == plain)
        #expect(throws: StoryUnavailableReason.self) { try substituted.get() }
    }
}
