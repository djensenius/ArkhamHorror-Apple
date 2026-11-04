@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Schema 0.1.63 repin (backend `05e53710`, djensenius/ArkhamHorror#304): the governed
/// `Fixtures/Contract` and `Fixtures/LocaleCatalog/Contract` bytes vendored from that commit
/// report 0.1.63, keep the 0.1.57 native client floor, agree with `ContractPin.current`, and
/// advertise the locale catalog with the `cardNames` packs and the card-only `pl` locale.
@Suite("Schema 0.1.63 contract drift")
struct Schema163ContractDriftTests {
    private static let revision = ContractRevision.literal(major: 0, minor: 1, patch: 63)
    private static let clientFloor = ContractRevision.literal(major: 0, minor: 1, patch: 57)

    @Test("ContractPin.current pins 0.1.63, records the 0.1.57 floor, and accepts 0.1.48 servers")
    func pinRevisions() {
        let pin = ContractPin.current
        #expect(pin.backendCommit == "05e537101118c5f8ceb70abae82ab7f59a355d93")
        #expect(pin.supportedSchemaRevision == Self.revision)
        #expect(pin.sourceNativeClientMinimumRevision == Self.clientFloor)
        #expect(pin.minimumServerSchemaRevision == .literal(major: 0, minor: 1, patch: 48))
        #expect(pin.expectedApiBasePath == "/api/v1")
    }

    @Test("Vendored 0.1.63 capabilities match the pin and evaluate as compatible")
    func capabilitiesMatchPin() throws {
        for name in ["capabilities", "capabilities-arkhamdb", "capabilities-locale-catalog"] {
            let caps = try ContractJSON.decode(ServerCapabilities.self, from: data(name))
            #expect(caps.schemaRevision == Self.revision, "\(name)")
            #expect(caps.nativeClientMinimumRevision == Self.clientFloor, "\(name)")
            #expect(
                caps.nativeClientMinimumRevision
                    == ContractPin.current.sourceNativeClientMinimumRevision,
                "\(name)"
            )
            guard case .compatible = CompatibilityEvaluator(pin: .current).evaluate(caps) else {
                Issue.record("\(name) is not compatible with ContractPin.current")
                continue
            }
        }
    }

    @Test("The manifest and replay attestation record schema 0.1.63")
    func manifestAndAttestationRevisions() throws {
        guard case let .object(manifest) = try value("manifest") else {
            Issue.record("manifest.json is not an object")
            return
        }
        #expect(manifest["schemaRevision"] == .string("0.1.63"))
        let attested = try Self.values(forKey: "contractSchemaRevision", in: value(
            "replay-attestation"
        ))
        #expect(attested == [.string("0.1.63"), .string("0.1.63")])
    }

    @Test("The 0.1.63 locale catalog advertises pl and a cardNames pack for de, en and pl")
    func localeCatalogAdvertisesCardNames() throws {
        let caps = try ContractJSON.decode(
            ServerCapabilities.self, from: data("capabilities-locale-catalog")
        )
        let advertisement = try #require(caps.localeCatalog)
        #expect(advertisement.catalogRevision == "1.6d23b2893fef02360a599a8aac212b36")
        #expect(advertisement.supportedLocales == ["de", "en", "pl", "pt-BR"])
        #expect(
            advertisement.manifestSha256
                == "6cf596192d97f4c7f40e3cfa51da04ce8fbec211dce1eac6875654348c6687fe"
        )
        let manifest = try LocaleCatalogManifest.validate(
            LosslessJSONParser.parse(localeCatalogData("locale-catalog-manifest")),
            against: advertisement
        ).get()
        let packs = Dictionary(uniqueKeysWithValues: manifest.locales.map { locale in
            (locale.locale, locale.chunks.map(\.pack))
        })
        #expect(packs == [
            "de": ["cardNames", "core"],
            "en": ["cardNames", "core", "nightOfTheZealot"],
            "pl": ["cardNames"],
            "pt-BR": ["core"],
        ])
        #expect(manifest.languageResolution["pl-PL"] == "pl")
    }

    private func data(_ name: String) throws -> Data {
        try Schema157Fixtures.contractData(name)
    }

    private func value(_ name: String) throws -> JSONValue {
        try LosslessJSONParser.parse(data(name))
    }

    private func localeCatalogData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/LocaleCatalog/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    private static func values(forKey key: String, in value: JSONValue) -> [JSONValue] {
        switch value {
        case let .object(object):
            object.keys.sorted().flatMap { name -> [JSONValue] in
                let nested = object[name].map { values(forKey: key, in: $0) } ?? []
                return name == key ? [object[name]].compactMap(\.self) + nested : nested
            }
        case let .array(array):
            array.flatMap { values(forKey: key, in: $0) }
        default:
            []
        }
    }
}
