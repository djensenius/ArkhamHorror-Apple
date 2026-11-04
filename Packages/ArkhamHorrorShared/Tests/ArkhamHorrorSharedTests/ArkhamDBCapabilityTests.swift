@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("ArkhamDB capability")
struct ArkhamDBCapabilityTests {
    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/Contract"
        ))
        return try Data(contentsOf: url)
    }

    @Test(
        "Only the opt-in capability enables ArkhamDB linking; old and legacy servers hide it"
    )
    func capabilityGate() throws {
        let enabled = try ContractJSON.decode(
            ServerCapabilities.self,
            from: fixtureData("capabilities-arkhamdb")
        )
        let outcome = CompatibilityEvaluator(pin: .current).evaluate(enabled)
        guard case let .compatible(capabilities, _, _) = outcome else {
            Issue.record("Expected a compatible 0.1.55 server")
            return
        }
        #expect(ServerCompatibility.modern(capabilities: capabilities)
            .supportsArkhamDBAccountLinking)
        let disabled = try ContractJSON.decode(
            ServerCapabilities.self,
            from: fixtureData("capabilities")
        )
        #expect(!ServerCompatibility.modern(capabilities: disabled.capabilities)
            .supportsArkhamDBAccountLinking)
        #expect(!ServerCompatibility.legacy.supportsArkhamDBAccountLinking)
        #expect(!ServerCompatibility.modern(capabilities: ["arkhamdb.account-linking.v2"])
            .supportsArkhamDBAccountLinking)
        #expect(!ServerCompatibility.modern(capabilities: []).supportsArkhamDBAccountLinking)
    }

    @Test("The write-back gate needs its own capability, independent of account linking")
    func writeBackCapabilityGate() throws {
        let enabled = try ContractJSON.decode(
            ServerCapabilities.self,
            from: fixtureData("capabilities-arkhamdb")
        )
        #expect(enabled.schemaRevision == ContractRevision(major: 0, minor: 1, patch: 63))
        #expect(enabled.capabilities.contains("arkhamdb.write-back.v1"))
        let compatibility = ServerCompatibility.modern(capabilities: enabled.capabilities)
        #expect(compatibility.supportsArkhamDBWriteBack)
        #expect(compatibility.supportsArkhamDBAccountLinking)
        // A 0.1.54 server advertised linking without write-back.
        var previous = enabled.capabilities
        #expect(previous.remove("arkhamdb.write-back.v1") != nil)
        let linkingOnly = ServerCompatibility.modern(capabilities: previous)
        #expect(linkingOnly.supportsArkhamDBAccountLinking)
        #expect(!linkingOnly.supportsArkhamDBWriteBack)
        #expect(!ServerCompatibility.legacy.supportsArkhamDBWriteBack)
        #expect(!ServerCompatibility.modern(capabilities: ["arkhamdb.write-back.v2"])
            .supportsArkhamDBWriteBack)
        #expect(ServerCompatibility.modern(capabilities: ["arkhamdb.write-back.v1"])
            .supportsArkhamDBWriteBack)
    }
}
