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
            Issue.record("Expected a compatible 0.1.54 server")
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
}
